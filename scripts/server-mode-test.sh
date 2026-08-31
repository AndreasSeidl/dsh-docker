#!/usr/bin/env bash
#
# Server-mode docker-compose boot test for the DeepSeek Harness container.
#
# Verifies docker-compose.server.yml actually boots into SERVER mode:
#   * the GUI is published on 0.0.0.0 by default (LAN access — the point of
#     server mode), so the host's LAN address answers too;
#   * harness data and workspaces sit on separate named volumes
#     (/home/dsh/.dsh and /workspaces);
#   * the entrypoint's server-mode seeding happened: /workspaces is the default
#     workspace root, the web profile pins the in-app directory browser
#     (directory-picker-browse), and the workspaces symlink is in the home dir.
#
# Like compose-test.sh this forces the LOCAL build via DSH_IMAGE with --no-build
# and starts on an alternate port. Run `make build` (or docker build) first.
#
# Usage:  DSH_IMAGE=dsh:dev ./scripts/server-mode-test.sh
set -uo pipefail

IMAGE="${DSH_IMAGE:-dsh:dev}"
PORT="${SERVER_MODE_TEST_PORT:-3083}"
FAILED=0

# ── image-era detection ───────────────────────────────────────────────────
# Two era-gates:
#   * server-mode profile seeding (cordis.patch.yml, the in-app directory
#     picker, and the /home/dsh/workspaces symlink) landed in 0.1.2-alpha.2;
#   * the baked healthcheck only matches the app in 0.1.1 (no 401 gate) or
#     from 0.1.2-alpha.2 (healthcheck learned to accept the gate's 401).
HARNESS_VER="$(docker run --rm --entrypoint dsh "$IMAGE" --version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
: "${HARNESS_VER:?cannot read '$IMAGE' --version}"
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
SESSION_LOCK=no;    version_ge "$HARNESS_VER" 0.1.2-alpha.1 && SESSION_LOCK=yes
PROFILE_WEB=no;     version_ge "$HARNESS_VER" 0.1.2-alpha.2 && PROFILE_WEB=yes
HEALTHCHECK_NEW=no; version_ge "$HARNESS_VER" 0.1.2-alpha.2 && HEALTHCHECK_NEW=yes
HEALTH_OK=no; [ "$SESSION_LOCK" = "no" ] || [ "$HEALTHCHECK_NEW" = "yes" ] && HEALTH_OK=yes
skip() { echo "SKIP: $*"; }
echo "  image $IMAGE → harness $HARNESS_VER (profile web: $PROFILE_WEB, era healthcheck ok: $HEALTH_OK)"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
check() { if "${@:2}" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

# "Reachable" includes the session lock's 401: once the per-run token lock arms,
# an unauthenticated GET / returns 401, which is alive, not unreachable. 2xx is
# the open first-boot state; 3xx the auth redirects.
reachable() {
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$2" "$1" || true)"
  case "$code" in
    2*|301|302|303|307|401) return 0 ;;
  esac
  echo "HTTP $code" >&2
  return 1
}
# Some images take up to a minute to boot the app behind the proxy (and the
# era-healthcheck branch skips the healthy-wait that used to absorb that);
# poll until it answers rather than asserting on first contact.
wait_reachable() { # wait_reachable <url> <max seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do
    reachable "$1" 4 >/dev/null 2>&1 && return 0
    i=$((i+1)); sleep 1
  done
  return 1
}

cleanup() {
  DSH_WEB_PORT="$PORT" docker compose -f docker-compose.server.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose not available; skipping server-mode boot test"
  exit 0
fi

if docker inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== server-mode compose boot (ports $PORT) =="
  DSH_WEB_PORT="$PORT" DSH_IMAGE="$IMAGE" \
    docker compose -f docker-compose.server.yml up -d --no-build >/dev/null 2>&1 \
    || { fail "docker compose (server) up"; exit 1; }

  if [ "$HEALTH_OK" = "yes" ]; then
    ok=0
    for _ in $(seq 1 60); do
      case "$(docker inspect -f '{{.State.Health.Status}}' dsh-server 2>/dev/null)" in
        healthy) ok=1; break ;;
      esac
      sleep 1
    done
    if [ "$ok" -eq 1 ]; then pass "container reached healthy (healthcheck)"
    else fail "container never became healthy ($(docker inspect -f '{{.State.Health.Status}}' dsh-server 2>/dev/null))"; fi
  else
    skip "baked healthcheck (pre-0.1.2-alpha.2 image: old curl -f check flips unhealthy under the 401 gate) — assert boot + serve instead"
    if [ "$(docker inspect -f '{{.State.Running}}' dsh-server)" = "true" ]; then
      pass "container is running (healthcheck semantics not applicable to this image era)"
    else
      fail "container is not running"
    fi
  fi

  check "web GUI reachable on localhost ($PORT, proxy answers)" \
    wait_reachable "http://127.0.0.1:$PORT/" 60

  # ── server mode publishes on 0.0.0.0 by default ──────────────────────────
  bind="$(docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostIp}}{{end}}{{end}}' dsh-server 2>/dev/null)"
  if [ "$bind" = "0.0.0.0" ]; then
    pass "server mode publishes on 0.0.0.0 by default (LAN access)"
  else
    fail "server mode published on '$bind' (expected 0.0.0.0)"
  fi
  LANIP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
  if [ -n "$LANIP" ]; then
    lan_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LANIP:$PORT/" || true)
    if [ "$lan_code" != "000" ]; then
      pass "host's LAN address ($LANIP) reaches the GUI (HTTP ${lan_code:-none})"
    else
      fail "host's LAN address ($LANIP) was NOT reachable (default must be open)"
    fi
  else
    echo "  (no global-scope LAN address found; skipping the LAN reachability check)"
  fi

  # ── volumes: harness data and workspaces are separate named volumes ───────
  mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}}@{{.Type}}{{end}}' dsh-server 2>/dev/null)"
  if printf '%s' "$mounts" | grep -q '/home/dsh/.dsh@volume'; then
    pass "/home/dsh/.dsh is a named volume"
  else
    fail "/home/dsh/.dsh is not a named volume (got: $mounts)"
  fi
  if printf '%s' "$mounts" | grep -q '/workspaces@volume'; then
    pass "/workspaces is a named volume"
  else
    fail "/workspaces is not a named volume (got: $mounts)"
  fi

  # ── server-mode entrypoint seeding ────────────────────────────────────────
  check "entrypoint defaulted DSH_WORKSPACE to /workspaces" \
    docker exec dsh-server sh -c 'test "${DSH_WORKSPACE:-}" = "/workspaces"'
  if [ "$PROFILE_WEB" = "yes" ]; then
    check "server-mode cordis.patch.yml was seeded into the harness home" \
      docker exec dsh-server test -f /home/dsh/.dsh/cordis.patch.yml
    if docker exec dsh-server dsh --profile web --dump-config 2>/dev/null \
         | grep -q '@deepseek-ai/dsh-host-directory-picker-browse'; then
      pass "composed web profile mounts directory-picker-browse (remote-safe picker)"
    else
      fail "composed web profile does not show directory-picker-browse (dump-config)"
    fi
    if docker exec dsh-server dsh --profile web --dump-config 2>/dev/null \
         | grep -A2 '^- id: directory-picker$' | grep -q 'disabled: true'; then
      pass "stock directory-picker-auto row is disabled in the composed profile"
    else
      fail "directory-picker-auto is not disabled in the composed profile (dump-config)"
    fi
    check "workspaces symlink present in the harness home" \
      docker exec dsh-server sh -c 'test -L /home/dsh/workspaces && test "$(readlink /home/dsh/workspaces)" = "/workspaces"'
  else
    skip "server-mode profile seeding (cordis patch, directory picker, workspaces symlink) — added in 0.1.2-alpha.2"
  fi
else
  echo "image $IMAGE not present — run 'make build' (or DSH_IMAGE=... docker build) first"
  exit 1
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "server-mode boot test: ALL PASS"
else
  echo "server-mode boot test: FAILURES ($FAILED)"
  exit 1
fi
