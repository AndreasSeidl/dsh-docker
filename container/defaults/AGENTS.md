# Container environment briefing (user-global AGENTS.md)
#
# You are running inside a Docker container for DeepSeek Harness
# (@deepseek-ai/dsh). This file is loaded by the harness as the fixed
# user-global baseline before every session, so the rules here apply to every
# project you work on in this container.

## The container

- OS: Debian bookworm (glibc). Runtime: Node.js 22, bash, git, curl.
- You run as the unprivileged user `dsh` (uid 1000 range). You cannot install
  system packages (no root); use user-level installs (npm/cargo --user, venv,
  etc.) when you need extra tooling.
- A C toolchain (gcc/g++/make/python3/pkg-config) IS installed, so building
  native npm packages (node-gyp) works without root.
- The filesystem is mounted read-only for system paths (`/app`, system dirs).
  Your writable directories are:
  - `/workspace` — YOUR workspace: the directory sessions start in and where
    you create and edit project files. Your files persist on the backing
    volume.
  - `/home/dsh/.dsh` — harness home: your `settings.yaml`, credentials,
    sessions, and profile plugins live here.
  - `/tmp` — scratch space (not persisted).

## Working in the workspace

- Put project files under `/workspace` (or a subdirectory). Do not rely on
  files outside `/workspace` and `/home/dsh/.dsh`: they are not part of the
  persistent volume and may be read-only.

## Harness configuration

- Model/provider + UI settings: edit `/home/dsh/.dsh/settings.yaml`.
- Provider credentials: `/home/dsh/.dsh/.credentials.yaml` (or environment
  variables listed in ~/.dsh). Keep secrets out of the workspace.
- The web profile lives at `/home/dsh/.dsh/profiles/web/`; your patch layer is
  `/home/dsh/.dsh/profiles/web/cordis.patch.yml` (hot-reloaded).
- Anything the harness reads from the environment passes straight through
  (provider keys, proxies, `DSH_*` flags).

## Installing profile plugins

`dsh plugin` manages profile plugins with pnpm (bundled in the image).
To add a plugin to the web profile, run, e.g.:

    dsh plugin --profile web add <package-name>
    # community market:  dsh plugin --profile web add dshmarket

Notes:
- Plugin installs run pnpm's dependency build scripts (allowed by default in
  this image) and, if needed, compile native modules with the bundled
  toolchain — no manual approval should be required.
- Installed plugins persist on the `/home/dsh/.dsh` volume.
- Restart the web server (or let it reload) for newly installed bundles to
  take effect.

## Network

- The web GUI is served on port 3080 by a bundled reverse proxy (Host/Origin
  rewritten internally); `dsh web` itself runs behind it on 127.0.0.1:30800.
  Do NOT start your own dev servers on either port. The GUI is session-locked:
  each boot prints a tokenized "dsh web:" URL in the container log, and any
  request without that token or its cookie is refused (401). There is no
  user-facing login beyond that log token — do not write API keys or other
  secrets into files that end up served or committed in this setup.
- Outbound network access is available (npm registry, model APIs, etc.).
