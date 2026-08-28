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

  docker compose down -v >/dev/null 2>&1
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
