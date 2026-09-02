#!/bin/sh
# Keep the README's stated support floor in sync with .supported-version — the
# single source of truth (see CONTRIBUTING.md, "Supported version floor").
#
#   ./scripts/sync-supported-version.sh          write the floor into README.md
#   ./scripts/sync-supported-version.sh --check  verify README matches (CI)
#
# Bump the floor by editing .supported-version, then run this script (or
# `make docs-sync`). The main-check CI job runs `--check` on every push, so the
# README and the floor can never drift apart.
set -eu

REPO="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
FLOOR_FILE="$REPO/.supported-version"
README="$REPO/README.md"

FLOOR="$(grep -m1 -E '^[0-9]' "$FLOOR_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
[ -n "$FLOOR" ] || { echo "error: no version parsed from $FLOOR_FILE" >&2; exit 1; }

# The README sentence that states the floor: the backtick-ed version token in
# the "Right now the floor is ..." line. Other version mentions in the README
# (the published-versions table, examples) are descriptive and not auto-synced.
CUR="$(sed -n 's|^Right now the floor is \*\*`\([^`]*\)`\*\*.*|\1|p' "$README" | head -n1 | tr -d '[:space:]' || true)"
[ -n "$CUR" ] || { echo "error: cannot locate the floor sentence in $README" >&2; exit 1; }

if [ "$CUR" = "$FLOOR" ]; then
  if [ "${1:-}" = "--check" ]; then
    echo "docs floor OK: README states $FLOOR == .supported-version"
  else
    echo "docs floor already in sync: $FLOOR"
  fi
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  echo "error: README says the floor is $CUR but .supported-version says $FLOOR — run" >&2
  echo "       ./scripts/sync-supported-version.sh (or make docs-sync) and commit the result" >&2
  exit 1
fi

# Rewrite the version token in the floor sentence.
awk -v floor="$FLOOR" '
  index($0, "Right now the floor is **`") == 1 {
    sub(/\*\*`[^`]*`\*\*/, "**`" floor "`**")
  }
  { print }
' "$README" > "$README.tmp" && mv "$README.tmp" "$README"
echo "docs floor synced: README now states $FLOOR (was $CUR)"
