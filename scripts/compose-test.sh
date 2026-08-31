#!/usr/bin/env bash
#
# Hardened docker-compose boot test for the DeepSeek Harness container.
#
# Verifies the hardened compose wiring in docker-compose.yml actually boots and
# serves under its lock-down:
#   * read-only rootfs (only the two volumes + /tmp are writable);
#   * the /tmp tmpfs stays EXEC-capable (the harness's spill store mkdtemp's
#     under /tmp and dynamic bundle loading imports/spawns from there);
#   * cap_drop ALL + no-new-privileges + a pids cap are applied;
#   * the web GUI is reachable through the published port (proxy mode).
#
# The compose file defaults to the published GHCR image, so this script forces
# it onto the LOCAL build via DSH_IMAGE=$IMAGE with `--no-build` (nothing is
# rebuilt/pulled); run `make build` first.
#
# The stack is brought up on DSH_WEB_PORT (default 3082) to avoid colliding
# with anything already on 3080, then torn down (volumes removed).
#
# Usage:  DSH_IMAGE=dsh:dev ./scripts/compose-test.sh
set -uo pipefail

IMAGE="${DSH_IMAGE:-dsh:dev}"
PORT="${COMPOSE_TEST_PORT:-3082}"
FAILED=0

# ── image-era detection ───────────────────────────────────────────────────
# 0.1.1-era images answer first-boot / 200 (no session lock); the baked
# `curl -f` healthcheck is correct for that era. From 0.1.2-alpha.1 the web
# app 401s an unauthenticated GET, so a pre-0.1.2-alpha.2 image (which still
# bakes the old curl -f healthcheck) is marked unhealthy by Docker for
# protocol reasons even though it boots and serves. We therefore assert
# "healthy" only when the baked healthcheck matches the era's gate behavior.
HARNESS_VER="$(docker run --rm --entrypoint dsh "$IMAGE" --version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
: "${HARNESS_VER:?cannot read '$IMAGE' --version}"
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
MIN_SUPPORTED="$(grep -m1 -E '^[0-9]' ./.supported-version 2>/dev/null | tr -d '[:space:]' || true)"
: "${MIN_SUPPORTED:?missing ./.supported-version — run the tests from the repo root}"
SUPPORTED=no; version_ge "$HARNESS_VER" "$MIN_SUPPORTED" && SUPPORTED=yes
SESSION_LOCK=no;   version_ge "$HARNESS_VER" 0.1.2-alpha.1 && SESSION_LOCK=yes
HEALTHCHECK_NEW=no; version_ge "$HARNESS_VER" 0.1.2-alpha.2 && HEALTHCHECK_NEW=yes
HEALTH_OK=no; [ "$SESSION_LOCK" = "no" ] || [ "$HEALTHCHECK_NEW" = "yes" ] && HEALTH_OK=yes
# Legacy-era accommodations below the supported floor are SKIPped; at or above
# the floor a skip firing is a bug (a supported image must pass every strict
# check, and the era gates therefore must never trigger for it).
skip() {
  if [ "$SUPPORTED" = "yes" ]; then
    fail "era skip fired on a supported image (floor $MIN_SUPPORTED): $*"
  else
    echo "SKIP: $*"
  fi
}
echo "  image $IMAGE → harness $HARNESS_VER (supported floor: $MIN_SUPPORTED → $SUPPORTED; session lock: $SESSION_LOCK, era healthcheck ok: $HEALTH_OK)"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
check() { if "${@:2}" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

# The GUI is "reachable" when the proxy answers from the app — 2xx is the open
# first-boot state, 3xx the auth redirects, and the steady state is the token
# lock answering 401 on an unauthenticated GET / (see Dockerfile HEALTHCHECK).
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
  DSH_WEB_PORT="$PORT" docker compose down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose not available; skipping compose boot test"
  exit 0
fi

if docker inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== hardened compose boot (proxy mode, ports $PORT) =="
  DSH_WEB_PORT="$PORT" DSH_IMAGE="$IMAGE" docker compose up -d --no-build >/dev/null 2>&1 \
    || { fail "docker compose up"; exit 1; }

  if [ "$HEALTH_OK" = "yes" ]; then
    # wait for the healthcheck to report healthy
    ok=0
    for _ in $(seq 1 60); do
      case "$(docker inspect -f '{{.State.Health.Status}}' dsh 2>/dev/null)" in
        healthy) ok=1; break ;;
      esac
      sleep 1
    done
    if [ "$ok" -eq 1 ]; then pass "container reached healthy (healthcheck)"
    else fail "container never became healthy ($(docker inspect -f '{{.State.Health.Status}}' dsh 2>/dev/null))"; fi
  else
    skip "baked healthcheck (pre-0.1.2-alpha.2 image: old curl -f check flips unhealthy under the 401 gate) — assert boot + serve instead"
    if [ "$(docker inspect -f '{{.State.Running}}' dsh)" = "true" ]; then
      pass "container is running (healthcheck semantics not applicable to this image era)"
    else
      fail "container is not running"
    fi
  fi

  check "web GUI reachable via the published port (proxy answers)" \
    wait_reachable "http://127.0.0.1:$PORT/" 60

  # ── the access fence: the PUBLISH ADDRESS, not anything in the container ──
  # Default (DSH_BIND_ADDRESS unset) must publish on 127.0.0.1 only, so the
  # kernel refuses connections from anywhere else — no Host-header trick can
  # get in, because nothing is listening for it.
  bind="$(docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostIp}}{{end}}{{end}}' dsh 2>/dev/null)"
  if [ "$bind" = "127.0.0.1" ]; then
    pass "default publishes on 127.0.0.1 (this machine only)"
  else
    fail "default published on '$bind' (expected 127.0.0.1)"
  fi
  LANIP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
  if [ -n "$LANIP" ]; then
    lan_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LANIP:$PORT/" || true)
    if [ "$lan_code" = "000" ]; then
      pass "default refuses the host's LAN address ($LANIP) at the kernel"
    else
      fail "default answered on the LAN address (HTTP $lan_code)"
    fi
    # ...and the Host-header trick that defeats an application-level check
    # must not help either.
    spoof=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: localhost" "http://$LANIP:$PORT/" || true)
    if [ "$spoof" = "000" ]; then
      pass "a spoofed 'Host: localhost' from the LAN gets no connection either"
    else
      fail "spoofed Host reached the GUI from the LAN (HTTP $spoof)"
    fi
  else
    echo "  (no global IPv4 address found; skipping the LAN-refusal checks)"
  fi

  # read-only rootfs: the image + /app must reject writes...
  if docker exec dsh sh -c 'echo x > /app/probe 2>/dev/null'; then
    fail "rootfs is writable (read_only not applied)"
  else
    pass "rootfs is read-only (image probe write rejected)"
  fi

  # ...while the volumes and /tmp stay writable.
  check "DSH_HOME volume writable" \
    docker exec dsh sh -c 'echo ok > /home/dsh/.dsh/.compose-probe && rm -f /home/dsh/.dsh/.compose-probe'
  check "workspace volume writable" \
    docker exec dsh sh -c 'echo ok > /workspace/.compose-probe && rm -f /workspace/.compose-probe'
  if docker exec dsh sh -c 'T=$(mktemp -d /tmp/t.XXXX); printf "#!/bin/sh\necho exec-ok\n" > "$T/x"; chmod +x "$T/x"; "$T/x"; rc=$?; rm -rf "$T"; exit $rc' >/dev/null 2>&1; then
    pass "tmpfs /tmp is exec-capable (spill store can run)"
  else
    fail "tmpfs /tmp is not exec-capable (noexec would break first boot)"
  fi

  caps="$(docker inspect -f '{{join .HostConfig.CapDrop ","}}' dsh 2>/dev/null)"
  if [ "$caps" = "ALL" ]; then pass "cap_drop ALL applied"
  else fail "cap_drop not ALL (got: $caps)"; fi
  sec="$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' dsh 2>/dev/null)"
  case "$sec" in
    *no-new-privileges*) pass "no-new-privileges applied" ;;
    *) fail "no-new-privileges missing (got: $sec)" ;;
  esac
  pids="$(docker exec dsh sh -c 'cat /sys/fs/cgroup/pids.max 2>/dev/null' 2>/dev/null)"
  if [ -n "$pids" ] && [ "$pids" != "max" ]; then pass "pid cap applied ($pids)"
  else fail "pid cap not applied (max=$pids)"; fi

  DSH_WEB_PORT="$PORT" docker compose down -v >/dev/null 2>&1

  echo "== DSH_BIND_ADDRESS=0.0.0.0 opens it to the network =="
  DSH_WEB_PORT="$PORT" DSH_BIND_ADDRESS=0.0.0.0 DSH_IMAGE="$IMAGE" \
    docker compose up -d --no-build >/dev/null 2>&1 || fail "compose up (LAN)"
  bind_lan="$(docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostIp}}{{end}}{{end}}' dsh 2>/dev/null)"
  if [ "$bind_lan" = "0.0.0.0" ]; then
    pass "DSH_BIND_ADDRESS=0.0.0.0 publishes on every interface"
  else
    fail "DSH_BIND_ADDRESS=0.0.0.0 published on '$bind_lan' (expected 0.0.0.0)"
  fi
  if [ -n "$LANIP" ]; then
    for _ in $(seq 1 40); do
      reachable "http://$LANIP:$PORT/" 3 && break
      sleep 1
    done
    open_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$LANIP:$PORT/" || true)
    case "$open_code" in
      2*|301|302|303|307|401)
        pass "the GUI is reachable on the host's LAN address ($LANIP)"
        ;;
      *)
        fail "LAN address still not reachable with DSH_BIND_ADDRESS=0.0.0.0 (HTTP $open_code)"
        ;;
    esac
  fi

  DSH_WEB_PORT="$PORT" DSH_BIND_ADDRESS=0.0.0.0 docker compose down -v >/dev/null 2>&1
  pass "docker compose down (volumes removed)"
else
  echo "image '$IMAGE' missing — run the build first (make build); skipping"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "COMPOSE TEST: ALL CHECKS PASSED"
else
  echo "COMPOSE TEST: $FAILED check(s) FAILED"
fi
exit "$FAILED"
