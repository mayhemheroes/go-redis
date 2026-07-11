# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — GO target (go-fuzz / go114-fuzz-build). Builds ON TOP of
# the org C/C++ base (ghcr.io/mayhemheroes/base) — clang links the go-fuzz libFuzzer
# archive — adding a pinned Go toolchain + go114-fuzz-build under /opt/toolchains/go,
# then runs the per-repo mayhem/build.sh.
#
# WHY /opt/toolchains (SPEC §6.2 items 8/9, §6.5):
#   Go's GOPATH/GOMODCACHE default to $HOME/go.  The commit build and the PATCH RL
#   re-run use DIFFERENT $HOMEs, so a cache left at the default would vanish under the
#   re-run identity.  We pin GOROOT/GOPATH/GOMODCACHE at FIXED, $HOME-independent paths
#   under /opt/toolchains so (a) the toolchain locks uniformly and (b) the module cache
#   the FIRST (online) build fills is found again — by the SAME absolute GOMODCACHE —
#   when build.sh re-runs OFFLINE at the PATCH tier.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t go-redis-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an
# empty value breaks clang.  build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ──────────────────────
# go-redis's go.mod requires `go 1.24`; pin 1.24.4 stable (SHA256-pinned tarball).
# go114-fuzz-build (OSS-Fuzz shim) + go-118-fuzz-build (AdamKorcz shim) build the
# LEGACY `func Fuzz([]byte) int` harness (//go:build gofuzz, -tags gofuzz), replicating
# OSS-Fuzz's `compile_go_fuzzer github.com/redis/go-redis/v9/fuzz Fuzz fuzz gofuzz`.
ARG GO_VERSION=1.24.4
ARG GO_SHA256=77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:${PATH}

USER root
RUN install -d /opt/toolchains/go-path \
 && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
 && go version \
 # go114-fuzz-build (OSS-Fuzz gofuzz shim, symlinked as `go-fuzz`) + go-118-fuzz-build
 # (AdamKorcz shim that go114-fuzz-build's generated entrypoint imports).  Installing
 # them seeds go-fuzz-dep + the AdamKorcz module into GOMODCACHE for offline re-runs.
 && go install github.com/mdempsky/go114-fuzz-build@latest \
 && ln -sf /opt/toolchains/go-path/bin/go114-fuzz-build /opt/toolchains/go-path/bin/go-fuzz \
 && go install github.com/AdamKorcz/go-118-fuzz-build@latest \
 # Hand the entire go-path tree to uid 2000 (mayhem) so the per-commit build and
 # the PATCH re-run (both non-root) can read/refresh the module cache at the same path.
 && chown -R 2000:2000 /opt/toolchains/go-path

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $GOMODCACHE (online, this first build) and builds the libFuzzer target(s).
RUN bash mayhem/build.sh

# Run a self-contained subset of go-redis's own Go test suite at build time; failing
# suite fails the image build.  The full suite needs a live Redis server; test.sh runs
# the server-free unit packages (RESP parser, hashtag, hscan, util, routing).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
