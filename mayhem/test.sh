#!/usr/bin/env bash
# Runs upstream's acutest suites (built by mayhem/build.sh) and reports CTRF counts parsed from
# each case's own "[ OK ]" / "[ FAILED ]" line. A neutered binary prints nothing -> 0 passed -> fail.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

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

passed=0; failed=0
cd "$SRC/tests"   # fixtures are referenced as ../models/...
for t in tester tester_features tester_c tess_tester; do
  bin="$SRC/build/tests/$t"
  if [ ! -x "$bin" ]; then echo "missing test runner $bin (build.sh should have built it)" >&2; failed=$((failed+1)); continue; fi
  out="$("$bin" 2>&1)"; rc=$?
  p=$(printf '%s\n' "$out" | grep -c '\[ OK \]')
  f=$(printf '%s\n' "$out" | grep -c '\[ FAILED \]')
  echo "$t: passed=$p failed=$f rc=$rc"
  if [ "$p" -eq 0 ] || ! printf '%s\n' "$out" | grep -q '^SUCCESS: All unit tests have passed\.'; then
    [ "$f" -eq 0 ] && f=1
    printf '%s\n' "$out" | tail -20 >&2
  fi
  passed=$((passed+p)); failed=$((failed+f))
done

emit_ctrf acutest "$passed" "$failed" 0
