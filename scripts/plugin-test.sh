#!/usr/bin/env bash
#
# Plugin-install test for the DeepSeek Harness container.
#
# Proves the runtime can install a real profile plugin end-to-end:
#   * the image actually carries the C/native toolchain (gcc g++ make python3
#     pkg-config) — the guard for the toolchain DEFAULT; if this fails the
#     image was built with INCLUDE_BUILD_TOOLS=0;
#   * pnpm is on PATH and its global config allows dependency build scripts;
#   * a plugin whose install compiles native code via node-gyp builds from
#     source with the bundled toolchain (no interactive `pnpm approve-builds`,
#     no missing package manager, no prebuild handed it the binary);
#   * the installed plugin (and its compiled binary) persists on the volume
#     and the harness still boots the web profile afterward.
#
# Uses node-pty (a native module that compiles via node-gyp) because it is
# exactly the class of dependency plugin installs routinely fail on.
#
# Note on the bundle registry: the harness only auto-registers packages that
# declare a `dsh.bundle` field; a plain dependency like node-pty is installed
# as a normal profile dependency (the harness logs a no-dsh.bundle note). We
# assert that machinery engaged, that the existing bundle list was not damaged,
# and that the profile still boots.
#
# Usage:  DSH_IMAGE=dsh:dev ./scripts/plugin-test.sh
set -uo pipefail

IMAGE="${DSH_IMAGE:-dsh:dev}"
PREFIX="dsh-plugin-$$"
FAILED=0

VOL="dsh-plugin-home-$PREFIX"
WSVOL="dsh-plugin-ws-$PREFIX"
docker volume create "$VOL" >/dev/null
docker volume create "$WSVOL" >/dev/null
trap 'docker volume rm "$VOL" "$WSVOL" >/dev/null 2>&1 || true' EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

LOG="/tmp/plugin-install-$PREFIX.log"

echo "== install node-pty via dsh plugin into a fresh volume =="
# --profile web add: the profile is created on first use if absent.
# HOME is left default (/home/dsh) so the baked pnpm global config applies.
docker run --rm \
  -e HOME=/home/dsh \
  -v "$VOL:/home/dsh/.dsh" \
  -v "$WSVOL:/workspace" \
  "$IMAGE" plugin --profile web add node-pty > "$LOG" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then pass "dsh plugin --profile web add node-pty exited 0"
else fail "dsh plugin add node-pty failed (exit $rc)"; tail -20 "$LOG"; fi

echo "== the runtime image carries the C/native toolchain =="
# Guard for the DSH_INCLUDE_BUILD_TOOLS default: native-addon compiles at
# install time need gcc/g++/make/python3/pkg-config IN the runtime image.
check_toolchain() {
  docker run --rm --entrypoint /bin/bash "$IMAGE" -lc 'set -e
    for b in gcc g++ make python3 pkg-config; do
      if ! command -v "$b" >/dev/null 2>&1; then echo "missing: $b"; exit 1; fi
    done
    gcc --version && make --version && python3 --version'
}
if check_toolchain; then
  pass "C/native toolchain present in the image (gcc g++ make python3 pkg-config)"
else
  fail "C/native toolchain missing from the image — native-addon plugin installs rely on it; build with INCLUDE_BUILD_TOOLS=1 (the default)"
fi

check_native() {
  # The native build must have produced the COMPILED pty.node in the profile
  # (build/Release is the node-gyp output dir; a downloaded prebuild would
  # land under prebuilds/, not here).
  docker run --rm --entrypoint /bin/bash \
    -e HOME=/home/dsh \
    -v "$VOL:/home/dsh/.dsh" \
    -v "$WSVOL:/workspace" \
    "$IMAGE" -lc \
    'test -f /home/dsh/.dsh/profiles/web/node_modules/node-pty/build/Release/pty.node && node -e "process.stdout.write(String(require(\"/home/dsh/.dsh/profiles/web/node_modules/node-pty\")))" >/dev/null 2>&1'
}
check_compiled() {
  # The install log must show node-gyp actually compiling from source, so a
  # prebuilt download cannot fake the native-build check.
  grep -q "node-gyp" "$LOG"
}
if check_native; then pass "node-pty native build present and loadable from the profile"
else fail "node-pty native build missing (build blocked or failed?)"; fi
if check_compiled; then pass "install log shows node-gyp compiling from source (not a prebuilt download)"
else fail "expected node-gyp compile evidence in the plugin install log"; grep -n "gyp\|prebuild" "$LOG" | head -5; fi

# The harness's bundle-registration machinery must have engaged (it announces
# when a package declares no dsh.bundle and installs it as a plain dependency).
if grep -qs "declares no dsh.bundle" "$LOG"; then
  pass "harness bundle-registration machinery engaged (no-dsh.bundle notice logged)"
else
  fail "expected the harness's no-dsh.bundle registration notice in plugin output"
  grep -n "bundle" "$LOG" | head
fi

# The pre-existing bundle list (the web profile's own layers) must be intact.
check_bundles() {
  docker run --rm --entrypoint /bin/bash \
    -e HOME=/home/dsh \
    -v "$VOL:/home/dsh/.dsh" \
    -v "$WSVOL:/workspace" \
    "$IMAGE" -lc \
    'node -e "const p=require(\"/home/dsh/.dsh/profiles/web/package.json\"); const b=p.dsh?.profile?.bundles??[]; process.stdout.write(b.join(\",\"))"'
}
bundles="$(check_bundles)"
case ",$bundles," in
  *,@deepseek-ai/dsh-base,*) pass "existing dsh-base bundle preserved" ;;
  *) fail "dsh-base missing from profile bundles (was: $bundles)" ;;
esac
case ",$bundles," in
  *,@deepseek-ai/dsh-web-app,*) pass "existing dsh-web-app bundle preserved" ;;
  *) fail "dsh-web-app missing from profile bundles (was: $bundles)" ;;
esac

echo "== the profile still boots the web GUI after the install =="
CID=$(docker run -d \
  -e HOME=/home/dsh -e DSH_WEB_BIND=0.0.0.0 -e DSH_WEB_PORT=3080 \
  -v "$VOL:/home/dsh/.dsh" -v "$WSVOL:/workspace" \
  "$IMAGE")
ok=0
for _ in $(seq 1 60); do
  if docker logs "$CID" 2>&1 | grep -q "dsh web: http"; then ok=1; break; fi
  sleep 1
done
status="$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || docker inspect -f '{{.State.Running}}' "$CID")"
docker rm -f "$CID" >/dev/null 2>&1
if [ "$ok" -eq 1 ]; then
  pass "web profile boots with the installed plugin (serving URL logged)"
else
  fail "web profile did not boot after plugin install (state: $status)"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PLUGIN TEST: ALL CHECKS PASSED"
else
  echo "PLUGIN TEST: $FAILED check(s) FAILED"
fi
exit "$FAILED"
