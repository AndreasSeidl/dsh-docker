# Testing — verifying the image, the stack, and plugins

Every verifier lives in `scripts/` and runs against a built runtime image
(`DSH_IMAGE`, default `dsh:dev`). Build first with `make build DSH_SRC=...`
(see [DEVELOPMENT.md](DEVELOPMENT.md)), then run any suite. All of them clean up
their volumes/containers on exit and exit non-zero on any failure.

## Smoke test — `scripts/smoke-test.sh`

```sh
DSH_IMAGE=dsh:dev ./scripts/smoke-test.sh
```

Boots the image the way `pnpm dsh web` would and verifies:

- the image boots and serves the GUI;
- the harness-home and workspace **volumes** work, including **persistence
  across a container restart** (seeding, then restart, then re-read);
- the **fixed in-container ports**: the bundled reverse proxy serving the GUI
  on 3080 (the port upstream documents), `dsh web` behind it on 127.0.0.1:30800;
- the **browser-session lock** (`dsh web` 0.1.2+): a request without the
  per-run token or its cookie gets `401`; the tokenized ready-URL line in the
  log exchanges for a session cookie (303 + Set-Cookie) and the GUI then
  answers `200` through the proxy — verified on both 3080 and 30800. The
  cookie is host-independent (the proxy always presents the fixed loopback
  authority to the app), so the LAN flow is asserted too: exchanged over a
  foreign `Host`, the same cookie validates over the container's own IP;
- that the container is **not** the access fence: the proxy binds every
  interface in its namespace and serves any Host, so a published port works
  (the fence is the publish address — see the compose test).

## Plugin install test — `scripts/plugin-test.sh`

```sh
DSH_IMAGE=dsh:dev ./scripts/plugin-test.sh
```

Proves the runtime can install a **real** profile plugin end-to-end. It is also
the **guard for the `INCLUDE_BUILD_TOOLS=1` default**:

- the image actually carries the C/native toolchain (`gcc g++ make python3
  pkg-config`) — if this fails, the image was built with `INCLUDE_BUILD_TOOLS=0`;
- pnpm is on PATH and its global config allows dependency build scripts;
- a plugin whose install compiles native code via node-gyp **builds from
  source** with the bundled toolchain (no interactive `pnpm approve-builds`, no
  missing package manager, no prebuilt binary handed to it) — it uses
  **node-pty**, exactly the class of native addon plugin installs routinely
  fail on;
- the installed plugin (and its compiled binary) persists on the volume and the
  harness still boots the web profile afterward.

It also exercises the bundle registry: node-pty installs as a plain profile
dependency (no `dsh.bundle`), and the test asserts that machinery engaged, that
the existing bundle list was not damaged, and that the profile still boots.

## Hardened compose boot test — `scripts/compose-test.sh`

```sh
DSH_IMAGE=dsh:dev ./scripts/compose-test.sh     # or: COMPOSE_TEST_PORT=3082 ...
```

Brings up the **hardened** `docker-compose.yml` stack and verifies the
lock-down actually holds. `docker-compose.yml` ships pointed at the **published
GHCR image**, so the test forces it onto your **local build** (`DSH_IMAGE=$IMAGE`
+ `--no-build`; nothing is pulled, nothing is rebuilt):

- read-only rootfs (only the two volumes + `/tmp` are writable);
- the `/tmp` tmpfs stays **EXEC-capable** (the harness's spill store
  `mkdtemp`'s under `/tmp` and dynamic bundle loading imports/spawns from there);
- `cap_drop ALL` + no-new-privileges + a pids cap are applied;
- the web GUI is reachable through the published port (host port → 3080);
- the **access fence**: by default the port is published on 127.0.0.1, so the
  host's own LAN address refuses the connection at the kernel — including a
  request that spoofs `Host: localhost` — while `DSH_BIND_ADDRESS=0.0.0.0`
  publishes on every interface and makes the LAN address reachable.

The stack comes up on host port `DSH_WEB_PORT` (default 3082, to avoid
colliding with anything on 3080) and is torn down with its volumes afterward.

## Server-mode compose boot test — `scripts/server-mode-test.sh`

```sh
DSH_IMAGE=dsh:dev ./scripts/server-mode-test.sh  # or: SERVER_MODE_TEST_PORT=3083 ...
```

Brings up **`docker-compose.server.yml`** (SERVER mode) on your local build and
verifies the mode actually differs from local in the ways that matter:

- the GUI is **published on `0.0.0.0` by default** (LAN), so the host's LAN
  address answers HTTP 200 — the inverse of the local compose test's fence;
- harness data and workspaces are separate **named volumes** (`/home/dsh/.dsh`
  and `/workspaces`);
- the server-mode entrypoint seeding ran: `DSH_WORKSPACE` defaults to
  `/workspaces`, `$DSH_HOME/cordis.patch.yml` was written, the composed web
  profile mounts `directory-picker-browse` with the stock `-auto` row disabled,
  and the `workspaces` symlink into `/workspaces` exists in the harness home.

The composed-profile checks (`dsh --profile web --dump-config`) are the proof
that the remote-safe in-app directory browser is what remote clients get — the
core of the server-mode workspace-selection story. The stack comes up on host
port `SERVER_MODE_TEST_PORT` (default 3083) and is torn down with its volumes
afterward.

## Trust-proxy token test — `scripts/trust-proxy-test.sh`

```sh
DSH_IMAGE=dsh:dev ./scripts/trust-proxy-test.sh  # or: TRUST_PROXY_TEST_PORT=3095 ...
```

Boots the server stack with **`DSH_WEB_AUTH_MODE=trust-proxy`** and proves the
bundled reverse proxy auto-exchanges the per-run session token:

- an unauthenticated `GET /` answers **200** (no 401, no token dance) — the
  proxy did the `?token=` exchange itself and replays the cookie;
- the printed `dsh web:` line carries **no `?token=`** (clients never need it);
- `/api/...` is **not 401** without a cookie — the proxy's replay cookie passed
  the app's session gate.

This is the "the layer in front is the real access control" mode for
tsdproxy/Tailscale, TLS+auth edges, and VPNs; see the `DSH_WEB_AUTH_MODE`
section in the README. The stack comes up on `TRUST_PROXY_TEST_PORT` (default
3095) and is torn down with its volumes afterward.

## Plugin test suite — `scripts/test-plugin-suite.sh` (`make test-plugins`)

```sh
DSH_IMAGE=dsh:dev ./scripts/test-plugin-suite.sh
SKIP_WEB=1 ./scripts/test-plugin-suite.sh      # skip the full web boot probe
```

Proves **any well-formed dsh plugin (v0.1+ public API)** works inside the
container, using the probe bundle at [test-plugins/](test-plugins/dsh-test-bundle).
End-to-end, in real containers: install + postinstall lifecycle, `dsh.bundle`
reconciliation into `dsh.profile.bundles`, patch-layer application at boot, an
**out-of-tree plugin mounting in-process** (`!!js` expressions included),
agent-preset authoring, clean removal, and that the `web` profile still boots
healthy with the bundle installed. 24 assertions across profiles `testbed` and
`web`.

`test-plugins/README.md` documents the **extension surfaces** the bundle probes —
what a plugin and an agent preset can touch on a harness build, and the trust
model (a plugin/preset is as powerful as the agent itself; there is no plugin
sandbox today). It is the reference for anyone extending the container's plugin
support.

## Developer tooling from the harness checkout

If you change the harness itself (not the container), use upstream's own dev
loop — this repo only consumes a checkout. The container build compiles the
checkout exactly like `pnpm run build`; see the build diagram in
[DEVELOPMENT.md](DEVELOPMENT.md).
