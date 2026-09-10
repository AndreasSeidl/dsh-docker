#!/usr/bin/env bash
# One-time migration: move the registry buildcache out of the release package.
#
# WHY: GHCR lists every tag in a repository path on the package page, and there
# is no way to hide one. The `buildcache-<version>-<arch>` tags therefore showed
# up among the real multi-arch releases on
# https://github.com/AndreasSeidl/dsh-docker/pkgs/container/dsh-docker.
# The cache moves to a SEPARATE, deliberately UNLINKED package
# (`<repo>-buildcache`) so the release package lists only `<version>` + `latest`.
# The cache is kept, not discarded: consecutive builds must stay warm.
#
# Tags are renamed on the way over — `buildcache-<version>-<arch>` becomes
# `<version>-<arch>`, since the prefix is redundant once the package holds
# nothing but cache. `prune-buildcache` in docker-publish.yml relies on that
# shape (and on "untagged means superseded cache" being unambiguous there).
#
# This is a cross-repository blob mount inside ONE registry: metadata only, no
# layer bytes move, and the SOURCE IS NEVER MUTATED. Deleting the old tags is a
# separate, later step (see the Phase 4 note in the same workflow) so nothing is
# removed until a real CI run has proven the new path warm. Re-running is safe:
# copying the same content to the same tags is idempotent.
#
# Usage:
#   scripts/migrate-buildcache.sh                 # dry run (default)
#   scripts/migrate-buildcache.sh --execute       # actually copy
#   SRC=... DST=... REGCTL=/path/to/regctl scripts/migrate-buildcache.sh
#
# Requires regctl (github.com/regclient/regclient) and a token with
# write:packages. The script logs in and out ITSELF, so it can be re-run any
# number of times with no setup: credentials go into a private, mode-0600
# REGCTL_CONFIG under a temp dir, and the exit trap logs out and deletes it —
# nothing is left behind, and a pre-existing ~/.regctl or ~/.docker login is
# never read or disturbed. The token comes from $GHCR_TOKEN, else `gh auth
# token`; it is passed on stdin, so it never appears in argv (visible to `ps`).
# CI pins regctl v0.11.6 (sha256
# 8e0e62a497fcdb8048d18aa927a139613176ba0531f412bc541044e28f9856bd for the
# linux-amd64 asset); use the same to keep copy semantics identical.
set -euo pipefail

SRC="${SRC:-ghcr.io/andreasseidl/dsh-docker}"
DST="${DST:-${SRC}-buildcache}"
REGCTL="${REGCTL:-regctl}"
REGISTRY="${SRC%%/*}"

EXECUTE=0
case "${1:-}" in
  --execute) EXECUTE=1 ;;
  --dry-run|'') ;;
  *) echo "usage: $0 [--dry-run|--execute]" >&2; exit 2 ;;
esac

command -v "$REGCTL" >/dev/null 2>&1 || { echo "error: regctl not found ($REGCTL)" >&2; exit 1; }

# --- credentials: isolated, and gone when this script exits -----------------
CONFIG_DIR="$(mktemp -d)"
chmod 700 "$CONFIG_DIR"
export REGCTL_CONFIG="$CONFIG_DIR/config.json"
LOGGED_IN=0

cleanup() {
  local rc=$?
  # Log out before dropping the file so the intent is explicit (and any future
  # server-side token revocation gets a chance to run), then remove the config
  # regardless — a failed logout must not leave credentials on disk.
  [ "$LOGGED_IN" = 1 ] && "$REGCTL" registry logout "$REGISTRY" >/dev/null 2>&1 || true
  rm -rf "$CONFIG_DIR"
  return $rc
}
trap cleanup EXIT

TOKEN="${GHCR_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  command -v gh >/dev/null 2>&1 \
    || { echo "error: no \$GHCR_TOKEN and gh not found" >&2; exit 1; }
  TOKEN="$(gh auth token)"
fi
[ -n "$TOKEN" ] || { echo "error: empty registry token" >&2; exit 1; }
USER_NAME="${GHCR_USER:-$(gh api user --jq .login 2>/dev/null || echo "${SRC#*/}")}"
USER_NAME="${USER_NAME%%/*}"

printf '%s' "$TOKEN" \
  | "$REGCTL" registry login "$REGISTRY" -u "$USER_NAME" --pass-stdin >/dev/null
LOGGED_IN=1
unset TOKEN

# Refuse to write into the release package by accident.
[ "$DST" != "$SRC" ] || { echo "error: DST must differ from SRC" >&2; exit 1; }
case "$DST" in
  *-buildcache) ;;
  *) echo "error: DST must end in -buildcache (got $DST)" >&2; exit 1 ;;
esac

mapfile -t TAGS < <("$REGCTL" tag ls "$SRC" | grep '^buildcache-' | sort)
[ "${#TAGS[@]}" -gt 0 ] || { echo "error: no buildcache-* tags on $SRC" >&2; exit 1; }

# Every tag must be buildcache-<version>-<amd64|arm64>; an unexpected shape means
# an assumption broke, and guessing at it would put junk in the new package.
for t in "${TAGS[@]}"; do
  [[ "$t" =~ ^buildcache-.+-(amd64|arm64)$ ]] \
    || { echo "error: unexpected cache tag shape: $t" >&2; exit 1; }
done

echo "source:      $SRC"
echo "destination: $DST"
echo "cache tags:  ${#TAGS[@]}"
[ "$EXECUTE" = 1 ] || echo "mode:        DRY RUN (pass --execute to copy)"
echo

FAILED=0
for t in "${TAGS[@]}"; do
  NEW="${t#buildcache-}"
  printf '  %s:%s -> %s:%s\n' "${SRC##*/}" "$t" "${DST##*/}" "$NEW"
  [ "$EXECUTE" = 1 ] || continue

  "$REGCTL" image copy "$SRC:$t" "$DST:$NEW"

  # A copy that reports success but lands different content is the one failure
  # mode that would silently cost warm builds; compare digests both sides.
  SD="$("$REGCTL" image digest "$SRC:$t")"
  DD="$("$REGCTL" image digest "$DST:$NEW")"
  if [ "$SD" != "$DD" ]; then
    echo "    FAIL: digest mismatch (src $SD, dst $DD)" >&2
    FAILED=$((FAILED + 1))
  else
    echo "    ok: $SD"
  fi
done

echo
if [ "$EXECUTE" != 1 ]; then
  echo "dry run: nothing copied"
  exit 0
fi
[ "$FAILED" = 0 ] || { echo "$FAILED tag(s) failed verification" >&2; exit 1; }
echo "copied and verified ${#TAGS[@]} cache tag(s) to $DST"
echo
echo "next: package settings for ${DST##*/} ->"
echo "  1. visibility: Public (new GHCR packages are created private)"
echo "  2. Repository source: confirm EMPTY (cache manifests carry no"
echo "     org.opencontainers.image.source label, so it should already be)"
echo "  3. Manage Actions access: Add Repository -> the repo running"
echo "     docker-publish -> Write role"
