# DeepSeek Harness container — build, run, tag, and publish targets.
#
# Variables:
#   DSH_SRC       path to a deepseek-harness checkout (default: ../deepseek-harness)
#   IMAGE         image name without registry (default: dsh)
#   REGISTRY      registry prefix for publish, e.g. ghcr.io/you (default: empty)
#   TAG           tag for build/publish (default: dev)
#
# Examples:
#   make build                 # build dsh:dev from ../deepseek-harness
#   make build TAG=0.1.0       # build dsh:0.1.0
#   make publish TAG=0.1.0 REGISTRY=ghcr.io/acme   # push acme/dsh:0.1.0
#   make run                   # run dsh:dev with a volume + port mapping
#
DSH_SRC      ?= $(abspath ../deepseek-harness)
IMAGE        ?= dsh
REGISTRY     ?=
TAG          ?= dev
CONTEXT_DIR  ?= .docker-context

# The client build embeds a commit hash; pass the real short commit of the
# staged source so the browser build metadata is truthful.
DSH_COMMIT   := $(shell git -C "$(DSH_SRC)" rev-parse --short=7 HEAD 2>/dev/null || echo b150a55)

IMAGE_TAG    := $(if $(REGISTRY),$(REGISTRY)/,)$(IMAGE):$(TAG)
BUILD_ARGS   := --build-arg DSH_CLIENT_COMMIT_HASH=$(DSH_COMMIT)

# Include the optional agent-CLI binaries? Off by default (saves ~560 MB).
BUILD_ARGS   += --build-arg DSH_INCLUDE_AGENT_CLIS=$(if $(filter 1 yes on,$(INCLUDE_AGENT_CLIS)),1,0)
# Include the runtime native-build toolchain? ON by default so `dsh plugin add`
# can compile native addons at runtime; set INCLUDE_BUILD_TOOLS=0 for a leaner
# image (plugin installs that need a compiler will then fail).
BUILD_ARGS   += --build-arg DSH_INCLUDE_BUILD_TOOLS=$(if $(filter 0 no off,$(INCLUDE_BUILD_TOOLS)),0,1)

# Host port for `make run` (inside the container the same value is used).
PORT         ?= 3080

# BuildKit cache ceiling kept by `make cache-prune` (see below). BuildKit's
# accounting can overshoot slightly; the in-use layer set always stays.
KEEP_STORAGE ?= 5G

# Optional registry cache ref to seed `docker build` from (the one the GitHub
# Actions workflow pushes as <registry>/<repo>:buildcache), e.g.
#   make build CACHE_REF=ghcr.io/acme/dsh:buildcache
CACHE_REF    ?=
# NB: the cache flag holds a comma, so it must be built through a variable —
# an inline `$(if ...)` splits on that comma and leaks `ref=`.
CACHE_FROM   := --cache-from=type=registry,ref=$(CACHE_REF)
CACHE_ARGS   := $(if $(CACHE_REF),$(CACHE_FROM))

.PHONY: help build publish run shell push tag clean context test-plugins cache-prune cache-reset install-local install-server docs-sync docs-check

.DEFAULT_GOAL := help

## Show this help.
help:
	@echo "dsh-container — targets (most people only need the published image;"
	@echo "                see README.md 'Quick start')"
	@echo ""
	@awk 'BEGIN { FS = ":.*" } \
	     /^## / { if (doc == "") doc = substr($$0, 4); next } \
	     /^[a-zA-Z0-9_-]+:/ { if (doc != "") printf "  \033[1m%-14s\033[0m %s\n", $$1, doc } \
	     { doc = "" }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables: DSH_SRC=$(DSH_SRC)  IMAGE=$(IMAGE)  TAG=$(TAG)  PORT=$(PORT)"
	@echo "           REGISTRY=$(REGISTRY)  INCLUDE_AGENT_CLIS=0/1  INCLUDE_BUILD_TOOLS=0/1"

## Build the image from the DSH_SRC checkout.
build: context
	docker build $(BUILD_ARGS) $(CACHE_ARGS) -t $(IMAGE_TAG) $(CONTEXT_DIR)

## Alias for build.
tag: build
	@echo "tagged: $(IMAGE_TAG)"

## Push the built image to REGISTRY (run `docker login` first).
publish: push

push:
	docker push $(IMAGE_TAG)

## Run the GUI from the locally built image on http://localhost:$(PORT).
## Publishes the container's GUI port (3080) on PORT and persists the harness
## home + agent workspace on volumes.
run:
	@echo "Starting $(IMAGE_TAG) -> http://localhost:$(PORT)"
	@echo "  volumes: dsh-home -> /home/dsh/.dsh, dsh-workspace -> /workspace"
	@echo "  (Ctrl-C stops it; the volumes keep your data.)"
	docker run --rm -it \
		--name dsh \
		-p "$(PORT):3080" \
		-v dsh-home:/home/dsh/.dsh \
		-v dsh-workspace:/workspace \
		$(IMAGE_TAG)

## Open a shell inside a throwaway container with the same mounts.
shell:
	docker run --rm -it \
		--entrypoint /bin/bash \
		-u dsh \
		-v dsh-home:/home/dsh/.dsh \
		-v dsh-workspace:/workspace \
		$(IMAGE_TAG)

## Rebuild the Docker build context from the source checkout.
context:
	./scripts/build-context.sh "$(DSH_SRC)"

## Run the container test-plugin suite (any well-formed dsh 0.1+ plugin) against DSH_IMAGE.
test-plugins:
	./scripts/test-plugin-suite.sh

## Install & start LOCAL mode (host dirs for harness data + workspace; this machine only).
install-local:
	./scripts/install.sh local

## Install & start SERVER mode (persistent volumes for harness data + workspaces; LAN access by default).
install-server:
	./scripts/install.sh server

## Remove the staged build context and local experiment dirs.
clean:
	rm -rf $(CONTEXT_DIR) .rt-exp .rt-exp2 .pnpm-store

## Bound the local BuildKit cache: prune back to KEEP_STORAGE (default 5G).
## Every `docker build` retains its intermediate layers (mode=max semantics), so
## without this the cache grows without bound (100 GB observed during round-3
## experiments). The most-recently-used ~5G survives, keeping warm rebuilds.
cache-prune:
	docker buildx prune -f --keep-storage=$(KEEP_STORAGE)

## Start from a zero cache (forces a cold rebuild; use sparingly).
cache-reset:
	docker buildx prune -af

## Restate the README's support floor from .supported-version (run after bumping the floor).
docs-sync:
	./scripts/sync-supported-version.sh

## Verify the README's stated support floor matches .supported-version (CI runs this).
docs-check:
	./scripts/sync-supported-version.sh --check
