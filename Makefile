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
# Include the runtime native-build toolchain? OFF by default (this is what
# keeps the image under 250 MB); set INCLUDE_BUILD_TOOLS=1 so `dsh plugin add`
# can compile native addons at runtime.
BUILD_ARGS   += --build-arg DSH_INCLUDE_BUILD_TOOLS=$(if $(filter 1 yes on,$(INCLUDE_BUILD_TOOLS)),1,0)

# Host port for `make run` (inside the container the same value is used).
PORT         ?= 3080

# Optional registry cache ref to seed `docker build` from (the one the GitHub
# Actions workflow pushes as <registry>/<repo>:buildcache), e.g.
#   make build CACHE_REF=ghcr.io/acme/dsh:buildcache
CACHE_REF    ?=
# NB: the cache flag holds a comma, so it must be built through a variable —
# an inline `$(if ...)` splits on that comma and leaks `ref=`.
CACHE_FROM   := --cache-from=type=registry,ref=$(CACHE_REF)
CACHE_ARGS   := $(if $(CACHE_REF),$(CACHE_FROM))

.PHONY: build publish run shell push tag clean context test-plugins

## Build the image from the DSH_SRC checkout.
build: context
	docker build $(BUILD_ARGS) $(CACHE_ARGS) -t $(IMAGE_TAG) $(CONTEXT_DIR)

## Alias for build.
tag: build
	@echo "tagged: $(IMAGE_TAG)"

## Publish the built image (you must already be logged into $(REGISTRY)).
publish: push

push:
	docker push $(IMAGE_TAG)

## Run the GUI: publish the web port, persist the harness home and the agent
## workspace on volumes. Defaults to reverse-proxy mode so the GUI is reachable
## over the network (loopback-only unless you override DSH_WEB_BIND).
run:
	@echo "Starting $(IMAGE_TAG) on http://127.0.0.1:$(PORT) (volumes: dsh-home -> /home/dsh/.dsh, dsh-workspace -> /workspace)"
	docker run --rm -it \
		--name dsh \
		-p "$(PORT):$(PORT)" \
		-e DSH_WEB_PROXY=1 \
		-e DSH_WEB_BIND=0.0.0.0 \
		-e DSH_WEB_PORT=$(PORT) \
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

## Remove the staged build context and local experiment dirs.
clean:
	rm -rf $(CONTEXT_DIR) .rt-exp .rt-exp2 .pnpm-store
