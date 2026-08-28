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

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
check() { if "${@:2}" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

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

  check "web GUI reachable via the published port (GET 200)" \
    curl -fsS -o /dev/null --max-time 20 "http://127.0.0.1:$PORT/"

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
      [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$LANIP:$PORT/")" = "200" ] && break
      sleep 1
    done
    open_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$LANIP:$PORT/" || true)
    if [ "$open_code" = "200" ]; then
      pass "the GUI is reachable on the host's LAN address ($LANIP)"
    else
      fail "LAN address still not reachable with DSH_BIND_ADDRESS=0.0.0.0 (HTTP $open_code)"
    fi
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
