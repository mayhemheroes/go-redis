#!/usr/bin/env bash
#
# go-redis/mayhem/test.sh — RUN a SELF-CONTAINED subset of redis/go-redis's OWN Go
# test suite (`go test -count=1 -v`) and emit a CTRF summary.  exit 0 iff no test failed.
#
# BEHAVIORAL ORACLE (§6.3 anti-reward-hacking):
#   We run tests with -v and grep the verbose output for specific known test names
#   (e.g. "TestReader_ReadLine" from internal/proto, "TestBytesToString" from
#   internal/util).  A no-op patch that neuters the program to exit(0) — or an
#   LD_PRELOAD sabotage that makes the compiled test binary exit(0) immediately —
#   produces NO "--- PASS: TestXxx" lines at all, so the grep fails and we emit
#   CTRF with failed=1.  A pure "passed=N, failed=0" exit-code check would be
#   reward-hackable (the sabotaged binary exits 0, Go runner sees 0 tests passed,
#   but the old fallback emitted 1 passed).
#
# Why a subset: go-redis's root package + most integration suites are ginkgo specs
# that REQUIRE a live Redis server.  We run the server-INDEPENDENT unit packages,
# anchored by `internal/proto` — the RESP reply parser, which is exactly the surface
# the OSS-Fuzz `Fuzz` harness drives.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
cd "$SRC"

# Server-independent unit packages.  internal/proto is the RESP parser (fuzzed surface).
PKGS=(
  ./internal/proto
  ./internal/hashtag
  ./internal/hscan
  ./internal/util
  ./internal/routing
)

# Behavioral anchor: these are stable test names in internal/proto and internal/util
# that assert known RESP parsing / byte conversion behavior.  They produce "--- PASS:"
# lines in -v output.  A sabotaged run (test binary LD_PRELOAD exit(0)) or a no-op
# patch produces no such lines.
REQUIRED_TESTS=(
  "TestReader_ReadLine"
  "TestBytesToString"
)

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

mkdir -p "$SRC/mayhem-build"
VOUT="$SRC/mayhem-build/gotest.verbose"
JSON="$SRC/mayhem-build/gotest.json"

echo "=== running: go test -count=1 -v ${PKGS[*]} ==="

# Capture verbose output for behavioral check; also capture JSON events for counts.
# -count=1 disables caching so the test binary is always executed fresh.
go test -count=1 -v "${PKGS[@]}" >"$VOUT" 2>&1 || true
go test -count=1 -json "${PKGS[@]}" >"$JSON" 2>"$SRC/mayhem-build/gotest.err" || true

# Print human-readable output for the build log.
tail -30 "$VOUT"
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count pass/fail/skip from JSON events.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass || true); FAILED=$(count_act fail || true); SKIPPED=$(count_act skip || true)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# BEHAVIORAL CHECK: verify that the known test names appear in the verbose output.
# A sabotaged/neutered run produces no "--- PASS: TestXxx" lines, failing this check.
for tname in "${REQUIRED_TESTS[@]}"; do
  if ! grep -q -- "--- PASS: ${tname}" "$VOUT" 2>/dev/null; then
    echo "BEHAVIORAL FAIL: expected '--- PASS: ${tname}' in verbose test output" >&2
    echo "  (neutered binary, LD_PRELOAD sabotage, or test removed — not behavioral)" >&2
    FAILED=$(( FAILED + 1 ))
  fi
done

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; treating as failure (behavioral oracle requires real output)" >&2
  FAILED=1
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
