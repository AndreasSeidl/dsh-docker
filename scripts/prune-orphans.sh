#!/usr/bin/env bash
# Delete UNREACHABLE untagged versions from the release package on GHCR.
#
# WHY: every publish pushes the two per-arch images BY DIGEST with no tag
# (push-by-digest=true) and then joins them into a tagged multi-arch index. A
# brand-new release orphans nothing — its two owners are referenced by the new
# index, and the previous release's index keeps its own <version> tag. But a
# REPUBLISH of an existing version (what `version: all` does to every supported
# version on a recipe change) orphans three manifests: the old index loses its
# tag to the new one, and the old index's two children stop being referenced by
# anything. So a single Dockerfile change costs 3 × |supported versions| dead
# manifests, and GHCR never evicts them. Runs that die between `build` and
# `merge` leave 2 orphan owners each, with no index.
#
# The rule is REACHABILITY, not manifest type:
#
#   protected = { digest of every tag } ∪ { every child those indexes reference }
#   delete    = untagged versions whose digest is not in `protected`
#
# An untagged version is deletable exactly when no tag can reach it. This is the
# distinction the workflow header used to treat as impossible: owner digests must
# never be deleted WHILE REFERENCED (version-deleting a referenced owner leaves
# <version>/latest un-pullable — it happened to 0.1.2-alpha.2 / latest), but an
# owner whose index has been superseded is referenced by nothing and is as dead
# as any other orphan.
#
# SAFETY. This script deletes untagged versions in the package that holds real
# releases, so the failure modes are the point:
#   * If the registry read fails, `protected` comes back EMPTY and "delete
#     everything unprotected" would delete the live owners. Every tag must
#     resolve AND its index must parse, or the script aborts having deleted
#     nothing.
#   * Tagged versions are never candidates.
#   * Deletion happens in batches, and after each batch every tag and every
#     child is re-resolved; the first unreachable one aborts the run.
#   * A manifest that cannot be read is kept, not deleted — an unreadable
#     manifest is an unknown, and unknowns are not garbage.
#   * Dry run is the default; --execute is required to delete.
#
# In CI this must run AFTER `merge`, never beside it: between `build` and `merge`
# the freshly pushed owners are legitimately unreferenced, and pruning then would
# delete the very digests `merge` is about to join. The docker-publish
# concurrency group serialises runs, so no other publish can be mid-flight.
#
# Usage:
#   scripts/prune-orphans.sh                      # dry run against the default image
#   scripts/prune-orphans.sh --execute
#   IMAGE=ghcr.io/owner/repo GH_TOKEN=... scripts/prune-orphans.sh --execute
#
# Locally: GH_TOKEN=$(gh auth token) with delete:packages. Needs regctl and jq.
set -euo pipefail

# `${GITHUB_REPOSITORY@L}` would trip `set -u` outside Actions; an empty
# fallback simply fails the "no tags listed" guard below instead.
_REPO="${GITHUB_REPOSITORY:-}"
IMAGE="${IMAGE:-ghcr.io/${_REPO@L}}"
REGCTL="${REGCTL:-regctl}"
BATCH_SIZE="${BATCH_SIZE:-20}"

EXECUTE=0
case "${1:-}" in
  --execute) EXECUTE=1 ;;
  --dry-run|'') ;;
  *) echo "usage: $0 [--dry-run|--execute]" >&2; exit 2 ;;
esac

command -v "$REGCTL" >/dev/null 2>&1 || { echo "error: regctl not found ($REGCTL)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }
[ -n "${GH_TOKEN:-}" ] || { echo "error: GH_TOKEN required" >&2; exit 1; }

OWNER="${IMAGE#*/}"; OWNER="${OWNER%%/*}"
PKG="${IMAGE##*/}"
# Never point this at the cache package: everything there is untagged-or-current
# by design and prune-buildcache owns it.
case "$PKG" in
  *-buildcache) echo "error: $PKG is the cache package; use prune-buildcache" >&2; exit 1 ;;
esac

if curl -fsS -H "Authorization: Bearer $GH_TOKEN" \
       "https://api.github.com/orgs/$OWNER" >/dev/null 2>&1; then
  SCOPE="/orgs/$OWNER"
else
  SCOPE="/user"
fi
BASE="https://api.github.com${SCOPE}/packages/container/$PKG"

# --- 1) protected set: every tag, plus every child its index references -------
PROTECTED="$(mktemp)"
TAGS_SEEN=0
trap 'rm -f "$PROTECTED" "${CANDIDATES:-}"' EXIT

mapfile -t TAGS < <("$REGCTL" tag ls "$IMAGE" 2>/dev/null || true)
[ "${#TAGS[@]}" -gt 0 ] || { echo "error: no tags listed for $IMAGE — refusing to prune" >&2; exit 1; }

for t in "${TAGS[@]}"; do
  [ -n "$t" ] || continue
  d="$("$REGCTL" manifest head "$IMAGE:$t" 2>/dev/null || true)"
  [ -n "$d" ] || { echo "error: cannot resolve tag '$t' — refusing to prune" >&2; exit 1; }
  body="$("$REGCTL" manifest get "$IMAGE:$t" --format raw-body 2>/dev/null || true)"
  [ -n "$body" ] || { echo "error: cannot read manifest for '$t' — refusing to prune" >&2; exit 1; }
  echo "$d" >> "$PROTECTED"
  # `.manifests[]?` is empty for a single-platform manifest, which is fine: such
  # a tag protects only itself.
  printf '%s' "$body" | jq -r '.manifests[]?.digest' >> "$PROTECTED"
  TAGS_SEEN=$((TAGS_SEEN + 1))
done

sort -u -o "$PROTECTED" "$PROTECTED"
PROT_COUNT="$(wc -l < "$PROTECTED")"
echo "image:     $IMAGE"
echo "tags:      $TAGS_SEEN"
echo "protected: $PROT_COUNT digests (tags + referenced children)"
[ "$PROT_COUNT" -ge "$TAGS_SEEN" ] \
  || { echo "error: fewer protected digests than tags — refusing to prune" >&2; exit 1; }

# --- 2) candidates: untagged versions outside the protected set ---------------
CANDIDATES="$(mktemp)"
PAGE=1
while :; do
  DATA="$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" \
             "$BASE/versions?per_page=100&page=$PAGE" 2>/dev/null || true)"
  [ -n "$DATA" ] || { echo "error: cannot list versions of $PKG" >&2; exit 1; }
  [ "$(printf '%s' "$DATA" | jq 'length')" != "0" ] || break
  printf '%s' "$DATA" | jq -r \
    '.[] | select((.metadata.container.tags // []) | length == 0)
         | [(.id|tostring), .name] | @tsv' >> "$CANDIDATES"
  PAGE=$((PAGE + 1))
done

TO_DELETE="$(mktemp)"
KEPT_PROTECTED=0
while IFS=$'\t' read -r id dig; do
  [ -n "$id" ] || continue
  if grep -qxF "$dig" "$PROTECTED"; then
    KEPT_PROTECTED=$((KEPT_PROTECTED + 1))
    continue
  fi
  # An unreadable manifest is an unknown, not garbage — leave it alone.
  if ! "$REGCTL" manifest head "$IMAGE@$dig" >/dev/null 2>&1; then
    echo "keep $dig (unreadable manifest)"
    continue
  fi
  printf '%s\t%s\n' "$id" "$dig" >> "$TO_DELETE"
done < "$CANDIDATES"

DEL_COUNT="$(wc -l < "$TO_DELETE")"
echo "untagged:  $(wc -l < "$CANDIDATES") ($KEPT_PROTECTED referenced by a tag, $DEL_COUNT unreachable)"

if [ "$DEL_COUNT" = "0" ]; then
  echo "nothing to prune"
  rm -f "$TO_DELETE"
  exit 0
fi

# --- 3) verification used before, between and after every batch ---------------
verify() {
  local bad=0 t d body c
  for t in "${TAGS[@]}"; do
    [ -n "$t" ] || continue
    d="$("$REGCTL" manifest head "$IMAGE:$t" 2>/dev/null || true)"
    [ -n "$d" ] || { echo "  BROKEN tag: $t"; bad=1; continue; }
    body="$("$REGCTL" manifest get "$IMAGE:$t" --format raw-body 2>/dev/null || true)"
    [ -n "$body" ] || { echo "  BROKEN index: $t"; bad=1; continue; }
    for c in $(printf '%s' "$body" | jq -r '.manifests[]?.digest'); do
      "$REGCTL" manifest head "$IMAGE@$c" >/dev/null 2>&1 \
        || { echo "  BROKEN child of $t: $c"; bad=1; }
    done
  done
  return $bad
}

if [ "$EXECUTE" != 1 ]; then
  echo
  echo "would delete $DEL_COUNT unreachable version(s):"
  cut -f2 "$TO_DELETE" | sed 's/^/  /'
  echo
  echo "dry run: nothing deleted (pass --execute)"
  rm -f "$TO_DELETE"
  exit 0
fi

echo
echo "baseline verification..."
verify || { echo "ABORT: reachability already broken before pruning" >&2; exit 1; }
echo "  all tags and children reachable"

OK=0
FAILED=0
N=0
while IFS=$'\t' read -r id dig; do
  if curl -fsS -X DELETE -H "Authorization: Bearer $GH_TOKEN" \
       "$BASE/versions/$id" >/dev/null 2>&1; then
    OK=$((OK + 1))
  else
    echo "  WARNING: cannot delete version $id (token lacks delete:packages?)"
    FAILED=$((FAILED + 1))
  fi
  N=$((N + 1))
  if [ "$((N % BATCH_SIZE))" = 0 ]; then
    printf 'deleted %d/%d — verifying... ' "$OK" "$DEL_COUNT"
    if verify; then
      echo "OK"
    else
      echo
      echo "ABORT: reachability broke after $OK deletions" >&2
      exit 1
    fi
  fi
done < "$TO_DELETE"
rm -f "$TO_DELETE"

echo
echo "final verification..."
verify || { echo "FAILURE: reachability broken after pruning" >&2; exit 1; }
echo "  all tags and children reachable"
echo "done: deleted $OK unreachable version(s), $FAILED failed, kept $KEPT_PROTECTED referenced"
