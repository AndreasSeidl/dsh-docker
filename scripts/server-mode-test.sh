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

# ── supported-version floor ───────────────────────────────────────────────
# The suite asserts the FULL server-mode contract (0.0.0.0 publish, volumes,
# profile seeding, Docker healthcheck that knows about the session lock's 401)
# and is only ever run against images at or above the minimum supported version
# (.supported-version = the oldest version that still passes every check).
# Older versions are unsupported: the tests do not run against them.
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

  ok=0
  for _ in $(seq 1 60); do
    case "$(docker inspect -f '{{.State.Health.Status}}' dsh-server 2>/dev/null)" in
      healthy) ok=1; break ;;
    esac
    sleep 1
  done
  if [ "$ok" -eq 1 ]; then pass "container reached healthy (healthcheck)"
  else fail "container never became healthy ($(docker inspect -f '{{.State.Health.Status}}' dsh-server 2>/dev/null))"; fi

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
  check "server-mode cordis.patch.yml was seeded into the harness home" \
    docker exec dsh-server test -f /home/dsh/.dsh/cordis.patch.yml
  if docker exec dsh-server dsh --profile web --dump-config 2>/dev/null \
       | grep -q '@deepseek-ai/dsh-host-directory-picker-browse'; then
    pass "composed web profile mounts directory-picker-browse (remote-safe picker)"
  else
    fail "composed web profile does not show directory-picker-browse (dump-config)"
  fi
  # The picker has TWO faces that both must be mounted as rows: the host
  # backend AND the ui-directory-picker-browse client surface (the -auto row
  # composes the pair itself; a lone backend row leaves the client flow holes
  # empty, so with no workspaces the GUI offers no picker at all). Guard the
  # client row explicitly — it is what makes the picker actually work.
  if docker exec dsh-server dsh --profile web --dump-config 2>/dev/null \
       | grep -q '@deepseek-ai/dsh-client-ui-directory-picker-browse'; then
    pass "composed web profile mounts the ui-directory-picker-browse client surface (picker usable)"
  else
    fail "composed web profile does not mount the ui-directory-picker-browse client surface (dump-config)"
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
