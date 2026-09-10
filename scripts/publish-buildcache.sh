#!/usr/bin/env bash
# Copy BuildKit's local OCI cache into GHCR only after the test matrix passes.
set -euo pipefail
CACHE="${1:?local cache directory required}"
DESTINATION="${2:?destination cache reference required}"
DIGEST="$(jq -er '.manifests | select(length == 1) | .[0].digest' "$CACHE/index.json")"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'invalid cache digest' >&2; exit 1; }
regctl image copy "ocidir://$CACHE@$DIGEST" "$DESTINATION"
