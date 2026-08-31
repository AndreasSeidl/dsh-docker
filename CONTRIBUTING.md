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

## Supported version floor

`.supported-version` in the repo root (see [.supported-version](.supported-version))
is the single source of truth for the oldest upstream harness version this repo
guarantees support for — the **minimum supported version**. It is defined as
*the oldest version that still passes the complete test suite* (see below), and
it is read by:

- the **test suites** (`scripts/{smoke,compose,server-mode,trust-proxy}-test.sh`):
  each reads the image's `dsh --version`, compares it to the floor, and **does
  not run at all against versions below it** (an unsupported version prints a
  "skipping" note and exits 0). The suites are written against the current
  contract, so anything at or above the floor must pass it fully — there are
  **no version-conditional fallbacks** to maintain;
- the **publish workflow** (`docker-publish.yml`): it refuses to build/publish
  an upstream version below the floor, and asserts the published image reports
  a version at or above it.

**Always make the trade-off when fixing:** when you change behavior or add a
feature, decide explicitly whether it can be back-ported to the current floor.
If it isn't worth it — bump the floor. Do **not** reintroduce backwards
compatibility into the suites (no SKIP branches for old versions): if an old
version stops passing the current contract, that is exactly what "below the
floor" means — its tests no longer run. Bumping the floor never deletes
anything from GHCR (owners stay as untagged digests forever — see below); it
only redefines which versions the tests and CI hold to the full contract.

**Set the floor to something reasonable:** the current release is the natural
default — the oldest version you are honestly willing to keep passing every
check. Never set it below a version that no longer passes the suite (there is
nothing to gain: the tests won't run on it and CI won't publish it), and never
so high that the current release itself goes unsupported. When a new upstream
version ships and passes, move the floor up to it; tags below it simply stop
being tested (they stay on GHCR as immutable artifacts).

Bumping the floor is a two-file change: edit `.supported-version`, then run
`make docs-sync` (or `./scripts/sync-supported-version.sh`) to restate the new
floor in the README — the README's floor sentence is generated from
`.supported-version`, and the `docs-supported-version` CI job runs it in
`--check` mode on every push, so the two can never drift.

Since the suites assert the full contract unconditionally, anything that differs
per version belongs at the floor, not in the tests: by the time you would write
a version check inside a suite, you should be considering whether the floor
needs to move instead.

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
  upstream tag starts the multi-arch build, and while a `docker-publish` run is
  already in progress the tick is skipped so the newest release is never built
  twice. Upstream currently releases everything as a prerelease
  (`dsh-v0.1.2-alpha.2`), so the poller looks at *all* `dsh-v*` tags rather than
  GitHub's `releases/latest` (which is empty until a stable ships);
- **manually** — `workflow_dispatch` accepts a `version` (tag or commit) input;
  leave it empty to build the **newest upstream release**.

There is deliberately **no schedule** and no `nightly` tag: only real upstream
releases are ever published (under `<version>`, with `:latest` aliasing the
newest one). A plain "rolling default branch" build is never pushed.

No PAT is needed: the poller queries upstream over git and GHCR with an
anonymous pull-scope token, and invokes the publish workflow as a reusable
workflow (`uses: ./.github/workflows/docker-publish.yml with: version: …`),
which carries the same GITHUB_TOKEN-backed GHCR push permissions it always
had.

`linux/amd64` and `linux/arm64` are both built and pushed **natively**: a two-job
matrix (`ubuntu-latest` for amd64, the `ubuntu-24.04-arm` hosted ARM runner for
arm64) builds each platform in parallel — no QEMU — and pushes each per-arch
image to GHCR **by digest with no tag** (`docker/build-push-action` with
`outputs: type=image,…,push-by-digest=true,name-canonical=true`), uploading the
digest as a tiny artifact. A `merge` job downloads both digests and creates the
published multi-arch index from the raw digest references
(`docker buildx imagetools create … ghcr.io/…@sha256:…`), tags it `<version>` +
`latest`, then **verifies** the published tags actually resolve (both platform
manifests reachable) and that the amd64 leg runs. Tags in the recipe repo and
harness versions map 1:1 (`v`-prefix optional).

> **Attribution.** The native push-by-digest + digest-artifact + merge-by-digest
> skeleton is adapted from
> [sredevopsorg/multi-arch-docker-github-workflow](https://github.com/sredevopsorg/multi-arch-docker-github-workflow)
> (MIT License, Copyright (c) 2025 SREDevOps.org). We keep our own version
> resolution, the post-merge verification, minimal `packages: write`
> permissions, and the *never version-delete* rule; their builder-context setup
> (`docker context create builders` + `endpoint:`) is not needed on the runners
> this repo uses.

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
was removed. Runs are infrequent (only on real upstream releases), so an
occasional cold start when the 7-day TTL evicts the cache first is fine.

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
> `sha256:380f67a3…` is the attestation stub, not a runnable image.

### Why the per-arch owners are untagged, and never deleted

A draft of this pipeline pushed the per-arch images under throwaway tags and
deleted those versions right after merging. GHCR's version deletion is
**not reference-aware**: deleting a per-arch "owner" version removes the
platform manifest the freshly created multi-arch index still points at, so
`docker pull` of the published tag fails with `manifest … not found`. That is
exactly what happened to `0.1.2-alpha.2` / `:latest` (published on the first
run where that cleanup actually executed); `0.1.1-rc.2` and `0.1.2-alpha.1`
survived only because their owners were never deleted. Two controlled
experiments on real GHCR then established the boundary: **GHCR exposes no
tag-removal API at all** — the registry `DELETE` endpoint answers
`405 UNSUPPORTED`, and the only REST primitive deletes a whole *version*, which
is precisely the destructive operation above. So this pipeline *pushes* the
owners **without any tag in the first place** (`push-by-digest`): they exist as
untagged, content-addressed versions — searchable by digest, never shown among
tagged releases — and nothing ever deletes them. The per-release owner rows
accumulate permanently as untagged "sha256:…" rows in the GHCR Versions view;
that is the intrinsic price of native multi-arch on GHCR, and the merge job's
verify step guards that each published tag is real.

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
