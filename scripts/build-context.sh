#!/usr/bin/env bash
#
# Stage a Docker build context for the DeepSeek Harness container.
#
# The context is a pruned copy of the harness source (everything the compile
# and the runtime need, nothing the image does not) plus the container helper
# files in .container/. The Dockerfile at the repo root consumes it.
#
# Two build-speedup helpers live here:
#   * `pnpm-manifests/` — a mirror of every workspace package.json the Docker
#     builder installs from (with the lockfile) BEFORE the source is copied,
#     so a source-only edit reuses the dependency-install layer.
#   * a fingerprint gate — re-staging is skipped when the staged inputs (the
#     same file set the tar copies + the container helpers + the Dockerfile)
#     are unchanged, so `make build` with nothing to do stays under a second.
#
# Usage:
#   DSH_SRC=/path/to/deepseek-harness ./scripts/build-context.sh
#   ./scripts/build-context.sh /path/to/deepseek-harness [--force]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT_DIR="${CONTEXT_DIR:-${REPO_ROOT}/.docker-context}"
STAMP="${REPO_ROOT}/.docker-context.stamp"
DSH_SRC="${DSH_SRC:-${1:-${REPO_ROOT}/../deepseek-harness}}"

FORCE=0
[ "${FORCE_CTX:-0}" = "1" ] && FORCE=1
case "$*" in
  *--force*) FORCE=1 ;;
esac

if [ ! -f "$DSH_SRC/pnpm-workspace.yaml" ] || [ ! -f "$DSH_SRC/pnpm-lock.yaml" ]; then
  echo "error: DSH_SRC='$DSH_SRC' does not look like a deepseek-harness checkout (missing pnpm-workspace.yaml / pnpm-lock.yaml)" >&2
  echo "       pass the checkout path: DSH_SRC=/path/to/deepseek-harness ./scripts/build-context.sh" >&2
  exit 1
fi

# The exact exclusion set the staging tar applies. The fingerprint hashes the
# same set so the gate reflects precisely what enters the image.
TAR_EXCLUDES=(--exclude='./.git' \
              --exclude='./.github' \
              --exclude='./.agents' \
              --exclude='./.claude' \
              --exclude='./.dsh-build' \
              --exclude='./node_modules' \
              --exclude='./docs' \
              --exclude='./*.tsbuildinfo')

fingerprint() {
  (
    set -e
    cd "$DSH_SRC"
    tar "${TAR_EXCLUDES[@]}" -cf - . 2>/dev/null
  ) | sha256sum -
  sha256sum "$REPO_ROOT/Dockerfile" \
    "$REPO_ROOT/container/bin/docker-entrypoint.sh" \
    "$REPO_ROOT"/container/scripts/*.mjs \
    "$REPO_ROOT"/container/defaults/* 2>/dev/null | sha256sum -
}

# Idempotence gate: reuse the already-staged context when nothing changed.
new_fp="$(fingerprint)"
if [ "$FORCE" -ne 1 ] && [ -f "$STAMP" ] && [ -d "$CONTEXT_DIR" ] \
   && [ "$(cat "$STAMP" 2>/dev/null)" = "$new_fp" ]; then
  echo "build context unchanged — reusing staged dir at $CONTEXT_DIR"
  exit 0
fi

rm -rf "$CONTEXT_DIR"
mkdir -p "$CONTEXT_DIR"

# Pruned source copy: everything needed to compile and run, nothing that would
# bloat the image (docs, git history, CI, and build cache). `website` stays:
# the tsc build type-checks scripts that import its docs manifest.
tar -C "$DSH_SRC" \
  "${TAR_EXCLUDES[@]}" \
  -cf - . | tar -C "$CONTEXT_DIR" -xf -

# Container helper files referenced by the Dockerfile, plus the Dockerfile
# itself (so the context builds standalone with `docker build .docker-context`).
mkdir -p "$CONTEXT_DIR/.container/bin" "$CONTEXT_DIR/.container/scripts" "$CONTEXT_DIR/.container/defaults"
cp "$REPO_ROOT/container/bin/docker-entrypoint.sh" "$CONTEXT_DIR/.container/bin/docker-entrypoint.sh"
cp "$REPO_ROOT"/container/scripts/*.mjs "$CONTEXT_DIR/.container/scripts/"
cp "$REPO_ROOT"/container/defaults/* "$CONTEXT_DIR/.container/defaults/"
cp "$REPO_ROOT/Dockerfile" "$CONTEXT_DIR/Dockerfile"

# Manifest mirror for the layer-caching install: every workspace package.json
# at its source-relative path under pnpm-manifests/. The Dockerfile copies the
# lockfile + these manifests first, runs `pnpm install` (which needs exactly
# those AND the root postinstall script and any patches — copied separately in
# the Dockerfile), and only then copies the real source.
mkdir -p "$CONTEXT_DIR/pnpm-manifests"
while IFS= read -r f; do
  [ "$f" = "$DSH_SRC/package.json" ] && rel="package.json" \
    || rel="${f#"$DSH_SRC"/}"
  dst="$CONTEXT_DIR/pnpm-manifests/$rel"
  mkdir -p "$(dirname "$dst")"
  cp "$f" "$dst"
done < <(find "$DSH_SRC" -name package.json \
          -not -path "*/node_modules/*" -not -path "*/.git/*")

printf '%s' "$new_fp" > "$STAMP"

echo "build context staged at $CONTEXT_DIR (source: $DSH_SRC)"
du -sh "$CONTEXT_DIR" || true
