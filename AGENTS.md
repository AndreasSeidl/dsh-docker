# dsh-docker — agent instructions

Builds and runs DeepSeek Harness as a Docker image.

## Docker under the `workspace-write` policy

The docker daemon runs **outside** the file sandbox, so essentially every
docker command works without escalating to `danger-full-access` (which is not
allowed for docker here anyway).

Two commands write CLI state under `$HOME/.docker` — outside the writable root —
and need that state redirected into the workspace:

- `docker build` (BuildKit default) — writes `$HOME/.docker/buildx/…`
- `docker login` — writes `$HOME/.docker/config.json`

```sh
export DOCKER_CONFIG=$PWD/.docker-cli   # git-ignored; already holds buildx state
docker build …
docker login …
```

`.docker-cli/` is git-ignored and holds the accumulated buildx state. Apply the
export on every command that writes — environment does not persist between tool
calls. The legacy builder (`DOCKER_BUILDKIT=0`) also avoids the buildx write.
