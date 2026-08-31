#!/bin/sh
#
# trust-proxy mode test — boots the server stack with DSH_WEB_AUTH_MODE=trust-proxy
# and proves the bundled proxy auto-exchanges the session token:
#   * an unauthenticated GET / answers 200 (no 401, no token dance),
#   * the printed "dsh web:" line carries NO ?token=,
#   * /api answers from the app (auth passed) instead of 401.
# Then tears the stack down (volumes removed).
#
# Usage:  DSH_IMAGE=dsh:dev ./scripts/trust-proxy-test.sh
set -eu

IMAGE="${DSH_IMAGE:-dsh:dev}"
PORT="${TRUST_PROXY_TEST_PORT:-3095}"
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
check() { if "${@:2}" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

cleanup() {
  DSH_WEB_PORT="$PORT" docker compose -f docker-compose.server.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose not available; skipping trust-proxy test"
  exit 0
fi

if ! docker inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image '$IMAGE' missing — run the build first (make build); skipping"
  exit 0
fi

# ── image-era detection ───────────────────────────────────────────────────
# DSH_WEB_AUTH_MODE=trust-proxy (the bundled proxy auto-exchanges the session
# token) landed in 0.1.2-alpha.2. An older image serves the 0.1.2 session lock
# but has no trust-proxy support, and a 0.1.1-era image has no session lock at
# all — for both, the whole test is skipped rather than failed. The baked
# healthcheck assertion is likewise only meaningful when it matches the era.
HARNESS_VER="$(docker run --rm --entrypoint dsh "$IMAGE" --version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
: "${HARNESS_VER:?cannot read '$IMAGE' --version}"
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
SESSION_LOCK=no;    version_ge "$HARNESS_VER" 0.1.2-alpha.1 && SESSION_LOCK=yes
TRUST_PROXY=no;     version_ge "$HARNESS_VER" 0.1.2-alpha.2 && TRUST_PROXY=yes
HEALTHCHECK_NEW=no; version_ge "$HARNESS_VER" 0.1.2-alpha.2 && HEALTHCHECK_NEW=yes
HEALTH_OK=no; { [ "$SESSION_LOCK" = "no" ] || [ "$HEALTHCHECK_NEW" = "yes" ]; } && HEALTH_OK=yes
skip() { echo "SKIP: $*"; }

if [ "$TRUST_PROXY" != "yes" ]; then
  echo "  image $IMAGE → harness $HARNESS_VER; DSH_WEB_AUTH_MODE=trust-proxy requires 0.1.2-alpha.2+ — skipping"
  skip "trust-proxy mode (added in 0.1.2-alpha.2; $HARNESS_VER predates it)"
  exit 0
fi
echo "  image $IMAGE → harness $HARNESS_VER (era healthcheck ok: $HEALTH_OK)"

echo "== trust-proxy mode (ports $PORT, DSH_WEB_AUTH_MODE=trust-proxy) =="
DSH_WEB_PORT="$PORT" DSH_IMAGE="$IMAGE" DSH_WEB_AUTH_MODE=trust-proxy \
  docker compose -f docker-compose.server.yml up -d --no-build >/dev/null 2>&1 \
  || { fail "docker compose (server, trust-proxy) up"; exit 1; }

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

# Await the token exchange (the first request may briefly wait for the replay
# cookie; a clean 200 proves the proxy auto-authenticated rather than the app
# being unscoped).
entry=""
for _ in $(seq 1 30); do
  entry="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" || true)"
  [ "$entry" = "200" ] && break
  sleep 1
done
if [ "$entry" = "200" ]; then
  pass "unauthenticated GET / answers 200 (no 401 — proxy did the token dance)"
else
  fail "unauthenticated GET / returned HTTP $entry (expected 200)"
fi

# The printed URL must be clean (no ?token=) in trust-proxy mode.
line="$(docker logs dsh-server 2>/dev/null | grep 'dsh web:' | grep -v 'open the' | tail -n 1 || true)"
if [ -n "$line" ] && ! printf '%s' "$line" | grep -q 'token='; then
  pass "printed 'dsh web:' line carries no token: $line"
else
  fail "printed 'dsh web:' line still carries a token (got: ${line:-none})"
fi

# /api must answer from the app (auth passed → not 401) without any cookie.
api="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$PORT/api/host.describe" || true)"
case "$api" in
  200|404|500) pass "/api/host.describe is not 401 without a cookie (HTTP $api)" ;;
  401) fail "/api/host.describe still 401s without a cookie in trust-proxy mode" ;;
  *)   fail "/api/host.describe unexpected HTTP $api" ;;
esac

if [ "$FAILED" -eq 0 ]; then echo "trust-proxy test: ALL PASS";
else echo "trust-proxy test: FAILURES"; exit 1; fi
