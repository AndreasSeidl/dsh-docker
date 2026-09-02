#!/usr/bin/env bash
#
# Smoke test for the DeepSeek Harness container: boots the image, exercises the
# harness-home and workspace volumes (including persistence across a restart),
# and verifies the fixed in-container layout (bundled reverse proxy on 3080,
# `dsh web` behind it on 127.0.0.1:30800) plus first-boot seeding.
#
# Usage:  DSH_IMAGE=dsh:dev ./scripts/smoke-test.sh
# Exits nonzero if any check failed.
set -uo pipefail

IMAGE="${DSH_IMAGE:-dsh:dev}"
PREFIX="dsh-smoke-$$"
PORT=$(( ( RANDOM % 20000 ) + 20000 ))
FAILED=0

# ── supported-version floor ───────────────────────────────────────────────
# The suite asserts the FULL contract and is only ever run against images at or
# above the minimum supported version (.supported-version = the oldest version
# that still passes every check). Older versions are unsupported: the tests do
# not run against them (a "skip", not a failure).
HARNESS_VER="$(docker run --rm --entrypoint dsh "$IMAGE" --version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
: "${HARNESS_VER:?cannot read '$IMAGE' --version}"
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
MIN_SUPPORTED="$(grep -m1 -E '^[0-9]' ./.supported-version 2>/dev/null | tr -d '[:space:]' || true)"
: "${MIN_SUPPORTED:?missing ./.supported-version — run the tests from the repo root}"
if ! version_ge "$HARNESS_VER" "$MIN_SUPPORTED"; then
  echo "  unsupported version: $IMAGE → harness $HARNESS_VER < floor $MIN_SUPPORTED — not supported, skipping"
  exit 0
fi
echo "  image $IMAGE → harness $HARNESS_VER (supported floor: $MIN_SUPPORTED)"

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
session_token() { # session_token <container> → the ?token= from the ready line
  docker logs "$1" 2>&1 | sed -n 's/.*?token=\([A-Za-z0-9_-]*\).*/\1/p' | head -1
}

echo "== image sanity =="
check "image exists" docker image inspect "$IMAGE" >/dev/null

echo "== image hygiene: no agent-CLI platform packages (size regressions) =="
# A version-pinned purge silently stops matching when the harness bumps these
# packages and the image quietly grows ~300 MB (seen: 0.1.1 -> 0.1.2-alpha.1,
# claude-agent-sdk 0.3.220->0.3.241, codex 0.147->0.149). The Dockerfile now
# purges by name-glob and fails the build on a survivor; this is a second,
# independent assertion straight on the final image.
check "no claude-agent-sdk/codex linux platform packages in the runtime image" \
  docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
    '! find /app/node_modules/.pnpm -maxdepth 1 -type d \( -name "@anthropic-ai+claude-agent-sdk-linux-*@*" -o -name "@openai+codex@*-linux-*" -o -name "@openai+codex-linux-*@*" \) -print -quit | grep -q .'

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

echo "== boot the web GUI with volumes (no configuration at all) =="
CID=$(docker run -d -p "$PORT:3080" \
  -v "$HVOL:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CID")
echo "  container $CID on host port $PORT"

if wait_ready "$CID"; then pass "web server ready (URL line logged)"
else fail "web server never printed its URL line"; docker logs "$CID" 2>&1 | tail -25; fi

echo "== fixed in-container ports + browser-session auth =="
# dsh web locks the GUI behind a per-run ?token= printed in the ready line: it
# 401s until the browser exchanges the token for an authority-bound cookie (303
# + Set-Cookie). The proxy forwards that dance untouched and rewrites the ready
# line to the public origin (localhost:<host port>), so the log's "dsh web:"
# URL is what the user opens.
TOK=$(session_token "$CID")
logline=$(docker logs "$CID" 2>&1 | grep "dsh web: http" | head -1)
if [ -n "$TOK" ] && printf '%s' "$logline" | grep -q "http://localhost:3080/?token="; then
  pass "tokenized ready URL printed and rewritten to the public origin ($logline)"
else
  fail "ready URL missing or not rewritten to the public origin (got: $logline)"; TOK="missing"
fi

# The whole dance over the PUBLISHED port — the exact path a real user takes:
check "published URL without a token is refused (401 — session-locked)" \
  test "$(http_code --max-time 8 "http://127.0.0.1:$PORT/")" = "401"
CJ=$(mktemp)
check "token exchange over the published port: /?token=… → 303 + cookie, then the GUI" \
  curl -fsSL -c "$CJ" -b "$CJ" -o /dev/null --max-time 15 "http://127.0.0.1:$PORT/?token=$TOK"
check "with the session cookie the GUI answers 200 via the published port" \
  curl -fsS -o /dev/null -b "$CJ" --max-time 8 "http://127.0.0.1:$PORT/"

# LAN: the cookie is NOT bound to a host name or IP — the proxy always
# presents the fixed loopback authority to the app, so a cookie exchanged (or
# the token used) from any machine/Host validates. Assert it: exchange via a
# foreign Host, then reuse the exact cookie value over the container's own IP
# with another foreign Host (curl jar domain matching is bypassed by sending
# the cookie by hand, so this tests the APP, not curl).
IPCID=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CID")
SESS=$(curl -s -D - -o /dev/null --max-time 10 -H "Host: 192.168.1.50:3080" \
  "http://$IPCID:3080/?token=$TOK" | sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' | head -1)
check "cookie is not host-bound: foreign Host/IP validates through the proxy (LAN)" \
  bash -c 'test -n "$1" && curl -fsS -o /dev/null --max-time 8 \
    -H "Host: laptop.lan:3080" -H "Cookie: $1" "http://$2:3080/"' _ "$SESS" "$IPCID"
rm -f "$CJ"

# The fixed in-container ports, verified from inside the container (the
# session lock 401s an unauthenticated probe — alive, not dead):
check "proxy chain up inside on 3080 (401 = app's auth gate, not a dead port)" \
  test "$(docker exec "$CID" curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:3080/)" = "401"
check "dsh web itself answers on 127.0.0.1:30800 (401 = auth gate)" \
  test "$(docker exec "$CID" curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:30800/)" = "401"

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
  -v "$HVOL:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers=("$CID")
wait_ready "$CID"
check "agent file still present after container recreation" \
  docker exec "$CID" grep -q "agent wrote this" /workspace/.smoke-marker
check "harness profile still present after recreation" \
  docker exec "$CID" test -f /home/dsh/.dsh/profiles/web/package.json

echo "== the container itself is not the access fence =="
# Who may reach the GUI is decided by the HOST port mapping (see the compose
# test), so the proxy must bind every interface in its namespace and serve any
# Host by default — otherwise a published port would have nothing to talk to.
PORT2=$((PORT+1))
CID2=$(docker run -d -p "$PORT2:3080" \
  -v "$HVOL2:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CID2")
wait_ready "$CID2"
IP2=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CID2")
check "published port answers (401 from the app's auth gate, not a dead port)" \
  test "$(http_code --max-time 10 "http://127.0.0.1:$PORT2/")" != "000"
any_host=$(http_code --max-time 10 "http://$IP2:3080/")
if [ "$any_host" != "000" ]; then
  pass "proxy binds every interface and forwards any Host (answered HTTP $any_host)"
else
  fail "proxy did not serve the container interface (HTTP $any_host)"
fi

echo "== first-boot seeding is idempotent (user edits survive) =="
PORT3=$((PORT+6))
docker exec "$CID2" sh -c 'echo "locale: en-US" >> /home/dsh/.dsh/settings.yaml'
CID3=$(docker run -d -p "$PORT3:3080" \
  -v "$HVOL2:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CID3")
check "user settings.yaml edit survives a recreation (no re-seed overwrite)" \
  docker exec "$CID3" grep -q "locale: en-US" /home/dsh/.dsh/settings.yaml
docker rm -f "$CID3" >/dev/null 2>&1

echo "== baked pnpm global config (plugin installs work out of the box) =="
check "pnpm on PATH" docker run --rm --entrypoint /bin/bash "$IMAGE" -lc 'command -v pnpm'
config="$(docker run --rm --entrypoint /bin/bash -e HOME=/home/dsh "$IMAGE" -lc 'pnpm config get dangerouslyAllowAllBuilds')"
check "pnpm dangerouslyAllowAllBuilds is set globally" test "$config" = "true"
store="$(docker run --rm --entrypoint /bin/bash -e HOME=/home/dsh -w /tmp "$IMAGE" -lc 'pnpm store path 2>/dev/null')"
check "pnpm store lives on the harness volume" \
  test "${store#/home/dsh/.dsh/.pnpm-store}" != "$store"

echo "== the bundled reverse proxy (always in front of dsh web) =="
PORT_PX=$((PORT+7))
CIDPX=$(docker run -d -p "$PORT_PX:3080" \
  -v "$HVOL2:/home/dsh/.dsh" \
  -v "$WVOL:/workspace" \
  "$IMAGE")
containers+=("$CIDPX")
wait_ready "$CIDPX"
px_code=$(http_code --max-time 10 --retry 5 --retry-connrefused --retry-delay 1 "http://127.0.0.1:$PORT_PX/")
if [ "$px_code" != "000" ]; then
  pass "proxy: published port answers with no config at all (HTTP $px_code)"
else
  fail "proxy: published port did not answer (000)"
fi
IPPX=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CIDPX")
# Any Host is forwarded — there is deliberately no Host allow-list (any client
# can claim any Host, so one would not be a boundary; the published port is).
any_px=$(http_code --max-time 8 "http://$IPPX:3080/")
if [ "$any_px" != "000" ]; then
  pass "proxy: serves any Host on the container interface (answered HTTP $any_px)"
else
  fail "proxy: did not serve the container interface (HTTP $any_px)"
fi
ws_code=000
# The web app's realtime channel is /api/remote.mux, and the upgrade handshake
# needs the same session cookie as the HTTP API.
CJPX=$(mktemp)
TOKPX=$(session_token "$CIDPX")
curl -fsSL -c "$CJPX" -b "$CJPX" -o /dev/null --max-time 15 "http://127.0.0.1:$PORT_PX/?token=$TOKPX" >/dev/null 2>&1
# A browser sends Origin + the session cookie on the upgrade; assert the proxy
# relays it into a real 101 (not just any response). Go through the published
# host port so the cookie jar (bound to 127.0.0.1) is actually sent.
ws_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -b "$CJPX" -H "Origin: http://localhost:$PORT_PX" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "http://127.0.0.1:$PORT_PX/api/remote.mux")
rm -f "$CJPX"
case "$ws_code" in
  101) pass "proxy: WebSocket upgrade to /api/remote.mux relayed (101 Switching Protocols)" ;;
  000) fail "proxy: WS upgrade got no response at all (000)" ;;
  502) fail "proxy: WS upgrade hit a proxy error (502)" ;;
  *)   fail "proxy: WS upgrade did not switch protocols (app answered $ws_code)" ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
  echo "SMOKE TEST: ALL CHECKS PASSED"
else
  echo "SMOKE TEST: $FAILED check(s) FAILED"
fi
exit "$FAILED"
