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
`TESTING.md`. Releases are driven by the publish workflows (see
[CI & publishing](#ci--publishing-docker-publish-workflow)) — no separate
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

Bumping the floor is a one-file change: edit `.supported-version` and push.
The README floor sentence is generated from it — the `main-check`
workflow re-states it and commits the result back on every push to main, so the
two can never drift and nothing needs editing by hand. (To re-state it locally,
`make docs-sync` or `./scripts/sync-supported-version.sh`; pull requests run the
same sync in `--check` mode.)

Since the suites assert the full contract unconditionally, anything that differs
per version belongs at the floor, not in the tests: by the time you would write
a version check inside a suite, you should be considering whether the floor
needs to move instead.

## CI & publishing (`docker-publish` workflow)

`.github/workflows/docker-publish.yml` builds and pushes to GHCR. It is never
triggered by a git tag — publishing happens from three entry points:

- **on new upstream releases** — `.github/workflows/check-upstream-release.yml`
  polls every hour (17 min past) for upstream `dsh-v*` release tags, compares
  them with the versions already on GHCR, and when a newer one is not yet
  published calls the publish workflow (via `workflow_call`) with that exact
  version. The check is one tiny job when there is nothing new; only a
  genuinely new upstream tag starts the multi-arch build, and while a
  `docker-publish` run is already in progress the tick is skipped so the newest
  release is never built twice. Upstream currently releases everything as a
  prerelease (`dsh-v0.1.2-alpha.2`), so the poller looks at *all* `dsh-v*` tags
  rather than GitHub's `releases/latest` (which is empty until a stable ships);
- **on image-affecting changes to main** — `.github/workflows/main-check.yml`
  runs after every push (and on PRs as a pre-merge gate): it syncs the README's
  supported-version floor, then builds the image once and asserts hygiene
  (agent-CLI purge intact, `/app` under the size ceiling). If that guard is
  green and the push touched image-affecting files (`Dockerfile`, `container/**`,
  `scripts/build-context.sh`), it calls the publish workflow with `version: all`
  — re-publishing every GHCR tag at/above the supported floor with the new
  recipe, exactly like a container-layer fix;
- **manually** — `workflow_dispatch` accepts a `version` (tag or commit) input;
  leave it empty to build the **newest upstream release**, or use `all` to
  re-publish every supported version.

There is deliberately **no schedule** and no `nightly` tag: only real upstream
releases are ever published (under `<version>`, with `:latest` aliasing the
newest one). A plain "rolling default branch" build is never pushed.

**Nothing user-facing is published until the new image passes the test suite.**
The two per-arch builds land on GHCR as *untagged* owner digests; a matrix
`test` job then runs the full suite (`scripts/smoke-test.sh`,
`server-mode-test.sh`, `compose-test.sh`, `trust-proxy-test.sh`) **natively on
each arch** — amd64 on the x64 runner, arm64 on the hosted ARM runner — against
its raw digest, the same tests run locally. Any single FAIL on either leg
aborts the run, so the `merge` job (which creates the `<version>`/`latest`
tags) only ever runs on a green image. A new upstream release with a breaking
change therefore fails here and nothing is tagged, instead of shipping a
broken image to GHCR. To reproduce the gate locally, run the four suites
against a digest ref:

```sh
# The leg you want to exercise: amd64 on an x64 host/runner; arm64 needs an
# arm64 host (or the hosted ARM runner the test matrix uses).
DGP="$(docker buildx imagetools inspect ghcr.io/<owner>/dsh-docker:<version> \
       | grep -B2 'Platform:  linux/amd64' | grep '^  Name:' \
       | sed -E 's/.*@(sha256:[0-9a-f]{64})/\1/')"
DSH_IMAGE="ghcr.io/<owner>/dsh-docker@$DGP" ./scripts/smoke-test.sh
DSH_IMAGE="ghcr.io/<owner>/dsh-docker@$DGP" ./scripts/server-mode-test.sh
DSH_IMAGE="ghcr.io/<owner>/dsh-docker@$DGP" ./scripts/compose-test.sh
DSH_IMAGE="ghcr.io/<owner>/dsh-docker@$DGP" ./scripts/trust-proxy-test.sh
```

All four suites also enforce the supported-version floor: a version below it is
reported as "unsupported, skipping" (exit 0), and since the build job already
refuses to build below the floor, a skip can never slip past this gate.


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

When **our own recipe** changes (Dockerfile, entrypoint, defaults, staging
script), `main-check` handles it: the merged push runs the hygiene guard and —
if green and image-affecting — re-publishes every supported version
(`docker-publish` with `version: all`).

The manual/override path (force a check or a publish without waiting):

1. Run "Run workflow" → `check-upstream-release` to force a fresh upstream poll
   without waiting for the hour.
2. Run "Run workflow" → `docker-publish` with a `version` input:
   - empty → build the **newest upstream release**;
   - `all` → rebuild every GHCR version tag at/above the supported floor;
   - a specific version (`0.1.2-alpha.2` or `dsh-v…`) → build that snapshot.
3. Watch the Actions run; a failure during build/push means the cache wasn't
   exported for the next run, so a retry may start cold.
