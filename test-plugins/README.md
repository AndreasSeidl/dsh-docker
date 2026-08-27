# Test plugins — DSH harness extension-surface probes

Two things live here:

1. **`dsh-test-bundle/`** — a complete, dependency-free test *plugin* (a.k.a.
   DSH *bundle*) designed so that containers/CI can prove **any well-formed
   plugin works** on a given harness build (the 0.1+ public API).
2. This overview: **what parts of the harness a plugin and an agent preset can
   touch**, which is what the bundle probes.

## The extension surfaces (what can touch what)

### 1. Plugins (`dsh plugin --profile <name> add <pkg>`)

A "plugin" is two things layered:

- **A profile dependency.** `dsh plugin` forwards `add/install/remove/...` to
  pnpm inside the profile directory (`$DSH_HOME/profiles/<name>`). The package's
  dependency graph, its `postinstall`/build scripts, and its native
  compilation all run here — with the container's baked pnpm global config
  (`dangerouslyAllowAllBuilds: true`) so build scripts proceed unattended.
  This alone is arbitrary code execution **at install time**, inside the
  profile, as the container user.

- **A patch layer (when it declares `"dsh": { "bundle": { "patch": "./<file>.yml" } }`).**
  After a successful `add`, `dsh` reconciles `dsh.profile.bundles` and, at
  boot, applies each bundle's patch list *on top of* the shipped bundle layers
  (dsh-base, then the mode bundle — web/headless — then user bundles, then the
  profile's own `cordis.patch.yml`; last write wins per row). A patch file is a
  top-level YAML list of loader entries that can:
  - **override/extend any boot row by id** — `config` (replace), `disabled`,
    `inject`, `intercept`, `isolate`, `name` (asserting rename), plus arbitrary
    keys;
  - **insert new rows** at the include root or into a named group — any plugin
    the harness can mount: services, toolsets, model providers, the web layer,
    session handlers, groups with their own isolation realm;
  - **name rows by bare specifier** — resolved from the profile directory, so a
    bundle can *be* a Cordis plugin and mount in-process (see the sentinel in
    `dsh-test-bundle/`), or add tools/settings contributed by the bundle;
  - embed **`!!js` expressions** — evaluated as JavaScript in the loader's
    expression scope (`with (ctx) eval(...)`, so it sees `process` and the
    whole Cordis context). Power = arbitrary in-process code at boot.
  Entries a given harness version doesn't ship are skipped with a warning
  (version tolerance), but a patch that *inserts* an unresolvable name fails
  that row loud.

So a plugin can reach: the boot entry list, every mounted service's config, the
profiles' own user patch layers (`$DSH_HOME/profiles/<name>/cordis.patch.yml`),
new plugin rows anywhere in a group tree, and — via install scripts — the
container filesystem as the `dsh` user.

### 2. Agent presets (`~/.dsh/.agent-presets/` and the shipped root)

A preset is a **directory** (named with its preset id, `[a-z0-9][a-z0-9-]*`)
containing `agent.cordis.yml`, optionally beside `preset.yml` (display
name/description/order). Roots: `$DSH_HOME/.agent-presets/` (user; discovered
hot — no restart) plus the shipped, read-only `config/agent-presets/` (system
trust) assembled by the launcher.

A preset is a **Cordis composition** mounted into the agent's own realm for a
session. Its rows compose real harness plugins, so a preset can declare:

- the **persona / system prompt** (`@deepseek-ai/dsh-persona`),
- the **model-facing tool catalog** (which toolsets the agent may call),
- the **PTY / terminal stack** (`dsh-terminal`, `dsh-tool-bash-persistent`,
  ...) with timing/policy config,
- **context behavior** (compact+full prompts, runtime-context snapshots),
- anything else mountable at session scope, including `!!js` expressions.

Trust model (from the harness docs): a preset composes an agent and therefore
**carries the same trust as shell access** — by design, because agents must be
able to author the environment they run in.

### 3. What that means in the container

Both mechanisms are **full code/config execution inside the running harness**
(install-time scripts run as the container user; patches run in-process at
boot; presets run per session). The container's own isolation — unprivileged
`dsh` user, dropped capabilities, no-new-privileges, and the `dsh-workspace`
volume standing between the agent and the host — is what bounds it externally;
modulo that, a plugin/preset is as powerful as the agent itself. There is no
"plugin sandbox" today, so treat `dsh plugin add <pkg>` as "run this package's
code as dsh" (which is exactly the model's intent).

## The probe bundle

`dsh-test-bundle/` is the executable form of the table above:

- install + postinstall marker,
- bundle reconciliation + static patch layer,
- an inserted row that mounts the bundle **itself** as an out-of-tree plugin
  (marker file + log),
- `!!js` expression evaluation,
- a sample agent preset,
- clean removal.

`scripts/test-plugin-suite.sh` (repo root) runs all of it in a real container
against profiles `testbed` and `web`, then reboots `web` to prove health.
