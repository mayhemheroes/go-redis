#!/usr/bin/env bash
#
# go-redis/mayhem/build.sh — build redis/go-redis's OSS-Fuzz Go fuzz target as a
# sanitized libFuzzer binary, REPLICATING OSS-Fuzz's compile_go_fuzzer.
#
# OSS-Fuzz target (projects/go-redis/build.sh):
#   compile_go_fuzzer github.com/redis/go-redis/v9/fuzz Fuzz fuzz gofuzz
# i.e. the LEGACY go-fuzz harness `func Fuzz(data []byte) int` (fuzz/fuzz.go,
# //go:build gofuzz), built with `go-fuzz` (go114-fuzz-build) under `-tags gofuzz`,
# then linked with $LIB_FUZZING_ENGINE.  The harness drives a *redis.Client
# (Set/Get/Incr/Scan) using the fuzz bytes as keys/values; the fuzzed surface is
# the go-redis command/RESP-reply path.  (No live redis server is present at fuzz
# time, so the commands error out — the exercised code is the client's command
# building + connection/reply handling, exactly as OSS-Fuzz runs it.)
#
# We produce:
#   /mayhem/fuzz_redis — OSS-Fuzz target (fuzz.Fuzz, go-fuzz -tags gofuzz, ASan+libFuzzer)
#   (output name is fuzz_redis, NOT fuzz: the repo has a `fuzz/` source DIR at /mayhem/fuzz,
#    so linking to /mayhem/fuzz would collide with that directory.)
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - The Dockerfile ENV pins GOROOT/GOPATH/GOMODCACHE under /opt/toolchains (absolute,
#     $HOME-independent) so the module cache the FIRST (online) build populates is found
#     again by the SAME GOMODCACHE path when this script re-runs offline.
#   - We set GOPROXY to the in-image file proxy FIRST, then network as fallback; the
#     offline re-run resolves entirely from the cache.  GOPROXY=off is NOT enough — it
#     blocks reading the version list from the cache, which `go get` needs.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not
# part of the Go libFuzzer link.  Keep ASan regardless of the base default.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# DWARF < 4 required by §6.2 item 10 so the verify-repo DWARF gate passes.
# Pass $GO_DEBUG_FLAGS on the final clang++ link of the .a → the first C shim
# compilation unit carries DWARF3.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Resolve modules offline-first from the in-image cache; network only as fallback.
# $(go env GOMODCACHE) reads the pinned ENV, so it is correct under ANY $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-fuzz builders rewrite source + need the AdamKorcz testing shim as a module dep.
# Add the module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because
# nothing imports it until the builder generates the entrypoint).  Order matters:
# tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: fuzz.Fuzz via go-fuzz (LEGACY []byte harness), -tags gofuzz ──
#     Exact replica of `compile_go_fuzzer github.com/redis/go-redis/v9/fuzz Fuzz fuzz gofuzz`.
echo "=== building fuzz (fuzz.Fuzz, go-fuzz -tags gofuzz) ==="
go-fuzz -tags gofuzz -func Fuzz -o "$SRC/mayhem-build/fuzz.a" \
    github.com/redis/go-redis/v9/fuzz
# Link with DWARF3 flags so the ELF carries DWARF < 4 symbols (§6.2 item 10).
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
    "$SRC/mayhem-build/fuzz.a" -o /mayhem/fuzz_redis
echo "built /mayhem/fuzz_redis"

echo "build.sh complete:"
ls -la /mayhem/fuzz_redis 2>&1 || true
