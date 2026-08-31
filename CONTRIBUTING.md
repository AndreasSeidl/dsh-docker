# Contributing

Thanks for improving the DeepSeek Harness container. This guides you through
the workflow, what CI does, and how releases/publishing work. For the technical
how-the-build-works detail see [DEVELOPMENT.md](DEVELOPMENT.md); for the test
suites see [TESTING.md](TESTING.md).

## Development setup

1. Clone a [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
   checkout (this repo builds it from source, it does not vendor it).
2. `make build DSH_SRC=/path/to/deepseek-harness` — stages a pruned context into
   `.docker-context/` and builds `dsh:dev`.
3. Iterate: the builder caches aggressively, so source-edit iterations are fast
   (~33 s warm); see [DEVELOPMENT.md](DEVELOPMENT.md) for build-speed mechanics.

## Before submitting

- **Run the test suites** against your built image — all of them, since they
  cover different surfaces:
  [TESTING.md](TESTING.md) lists the smoke, plugin, compose, and plugin-suite
  verifiers and their exact invocations.
- If the default runtime toolchain is part of your change, keep
  `scripts/plugin-test.sh` green — it is the guard for `INCLUDE_BUILD_TOOLS=1`.

## Conventions

Follow the commit style already in the log: `feat:`, `fix:`, `docs:`, `ci:`,
`container:` for image/wiring changes, etc. Keep user-facing usage changes in
`README.md`; the maintainer-facing depth lives in `DEVELOPMENT.md` /
`TESTING.md`. Releases are driven purely by git tags (below) — no separate
release branch juggling.

## CI & publishing (`docker-publish` workflow)

`.github/workflows/docker-publish.yml` builds and pushes to GHCR:

- **on every tag** — `git tag v0.1.1-rc.2` (or `0.1.1-rc.2`) pins the harness
  at that upstream version and publishes
  `ghcr.io/<owner>/dsh-docker:<version>` and `:latest`;
- **automatically on new upstream releases** — `.github/workflows/check-upstream-release.yml`
  polls every hour (17 min past) for upstream `dsh-v*` release tags, compares
  them with the versions already on GHCR, and when a newer one is not yet
  published calls this workflow (via `workflow_call`) with that exact version.
  The check is one tiny job when there is nothing new; only a genuinely new
  upstream tag starts the multi-arch build, and a tag whose per-arch build is
  already in flight is never re-triggered. Upstream currently releases
  everything as a prerelease (`dsh-v0.1.2-alpha.2`), so the poller looks at
  *all* `dsh-v*` tags rather than GitHub's `releases/latest` (which is empty
  until a stable ships);
- **weekly (Mon 03:30 UTC)** — rebuilds the upstream default branch as
  `ghcr.io/<owner>/dsh-docker:nightly`;
- **manually** — `workflow_dispatch` accepts a `version` (tag or commit) input.

No PAT is needed: the poller queries upstream over git and GHCR with an
anonymous pull-scope token, and invokes the publish workflow as a reusable
workflow (`uses: ./.github/workflows/docker-publish.yml with: version: …`),
which carries the same GITHUB_TOKEN-backed GHCR push permissions it always
had.

`linux/amd64` and `linux/arm64` are both built and pushed, **natively**: a two-
job matrix (`ubuntu-latest` for amd64, the `ubuntu-24.04-arm` hosted ARM runner
for arm64) builds each platform in parallel — no QEMU — and a `merge` job joins
them into one multi-arch manifest with `docker buildx imagetools create`
(published under `<version>`/`latest`, or `nightly`). Earlier versions
cross-built arm64 with QEMU, which is ~1 h cold and made the arm64 leg look
stuck; native building removed that. Tags in the recipe repo and harness
versions map 1:1 (`v`-prefix optional).

The per-arch builds push under **throwaway** `dsh-int-<arch>-<run-id>` tags
purely as a handle for the merge step; after the multi-arch index is created
the merge job deletes those versions via the GitHub REST API, so GHCR keeps
only the versioned **multi-arch** rows (`<version>`, `latest`, `nightly`) —
not `<version>-amd64`/`<version>-arm64` rows. (The platform *images*
themselves unavoidably still appear as untagged digest rows: a multi-arch
index must reference them in the same package, and GHCR lists every manifest.
That is true of every multi-arch container on GHCR/Docker Hub.) If the merge
job's in-workflow cleanup hits a permission wall, it logs a warning and the
`dsh-int-*` versions can be deleted manually in the GHCR UI.

CI cache is **`type=gha` only** (GitHub's Actions cache), exported with
`mode=max` and a per-arch `scope` so the builder stages stay warm between runs.
It is *self-managing*: GitHub caps it per repository (~10 GB on public repos)
and evicts LRU / 7-day-stale entries, so it cannot grow without bound. Note
that the cache is only seeded by a **successful** run — a run that dies during
push or build aborts the cache export, so the next build starts cold. Earlier
versions also exported a `type=registry` cache tagged `<image>:buildcache` on
GHCR — that one is **additive with no automatic size eviction** and would have
accumulated cache blobs on GHCR indefinitely (the registry analogue of the
bounded-on-the-host cache problem in [DEVELOPMENT.md](DEVELOPMENT.md)), so it
was removed. The weekly `nightly` build tolerates an occasional cold-start if
the 7-day TTL evicts the cache first.

> **Why some published tags show an `unknown/unknown` platform.** Builds before
> the `provenance: false` change were pushed by `docker/build-push-action` with
> BuildKit's default `provenance=true`, which attaches one **SLSA provenance
> attestation** per platform. Those attestations sit in the image index as extra
> entries with no `os`/`arch`, so tools that list platforms (`docker manifest
> inspect`, the GHCR/registry "Architectures" UI) show them as
> `unknown/unknown` (two real platforms + the attestations, which the UI often
> collapses into one row). They are harmless and carry no content layers. New
> builds set `provenance: false`/`sbom: false`, so future images have clean
> two-platform indexes; the `unknown/unknown` entries only linger on the older
> tags. And don't pin by one of their digests — a digest like
> `sha256:380f67a3…` is the attestation stub, not a runnable image (see the
> merge job below for the real per-arch digests).

## Making a release

For the dsh-container repo itself there is usually **nothing to do**: when
upstream cuts a new `dsh-v<version>` release, the hourly
`check-upstream-release` workflow picks it up and publishes
`ghcr.io/<owner>/dsh-docker:<version>` (+ `:latest`) on its own.

Pushing a tag is the explicit/override path (e.g. to force-build or to pin a
specific version before the next hourly poll):

1. Tag the commit: `git tag v0.1.1-rc.2` (the `v` prefix is optional; the tag is
   also the harness version to build at).
2. `git push origin v0.1.1-rc.2` — the workflow builds both archs natively and
   publishes `ghcr.io/<owner>/dsh-docker:<version>` (+ `:latest`).
3. Watch the Actions run; a failure during build/push means the cache wasn't
   exported for the next run, so a retry may start cold.

(You can also run the check workflow manually via `workflow_dispatch` — "Run
workflow" → `check-upstream-release` — to force a fresh poll without waiting
for the hour, and the publish workflow manually with a `version` input.)
