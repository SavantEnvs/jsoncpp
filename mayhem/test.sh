#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

TB="$SRC/build-tests/bin"
for b in "$TB/jsoncpp_test" "$TB/jsontestrunner_exe"; do
  [ -x "$b" ] || { echo "test.sh: $b missing — mayhem/build.sh should have built it" >&2; emit_ctrf jsoncpp 0 1 0; exit 1; }
done
passed=0 failed=0

# 1) upstream unit tests (src/test_lib_json): "All N tests passed" / "P/T tests passed (F failure(s))"
out=$("$TB/jsoncpp_test" 2>&1); echo "$out" | tail -3
if   m=$(echo "$out" | sed -n 's/^All \([0-9][0-9]*\) tests passed$/\1/p' | tail -1) && [ -n "$m" ]; then
  passed=$((passed + m))
elif m=$(echo "$out" | sed -n 's|^\([0-9][0-9]*\)/\([0-9][0-9]*\) tests passed (\([0-9][0-9]*\) failure.*|\1 \3|p' | tail -1) && [ -n "$m" ]; then
  set -- $m; passed=$((passed + $1)); failed=$((failed + $2))
else
  echo "test.sh: no jsoncpp_test summary line (program neutered or crashed?)" >&2; failed=$((failed + 1))
fi

# 2) upstream reader/writer golden-file suite (test/runjsontests.py over test/data/*.json -> *.expected)
out=$(python3 -B "$SRC/test/runjsontests.py" "$TB/jsontestrunner_exe" "$SRC/test/data" 2>&1); echo "$out" | tail -3
if   m=$(echo "$out" | sed -n 's/^All \([0-9][0-9]*\) tests passed\.$/\1/p' | tail -1) && [ -n "$m" ]; then
  passed=$((passed + m))
elif m=$(echo "$out" | sed -n 's/^Test results: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed\.$/\1 \2/p' | tail -1) && [ -n "$m" ]; then
  set -- $m; passed=$((passed + $1)); failed=$((failed + $2))
else
  echo "test.sh: no runjsontests summary line (program neutered or crashed?)" >&2; failed=$((failed + 1))
fi

# 3) known-answer probes, compared by bash/diff (outside any no-op'd binary): parse a fixture
#    with jsontestrunner_exe and require the exact golden dump / the exact error message.
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
probe_ok() {  # <fixture basename>
  cp "$SRC/test/data/$1.json" "$W/$1.json"; rm -f "$W/$1.actual"
  "$TB/jsontestrunner_exe" "$W/$1.json" >/dev/null 2>&1 && [ -f "$W/$1.actual" ] \
    && diff -q "$SRC/test/data/$1.expected" "$W/$1.actual" >/dev/null
}
for f in legacy_test_basic_01 legacy_test_array_01 legacy_test_object_01 legacy_test_string_unicode_01; do
  [ -f "$SRC/test/data/$f.expected" ] || { echo "test.sh: fixture $f missing" >&2; failed=$((failed + 1)); continue; }
  if probe_ok "$f"; then passed=$((passed + 1)); else echo "KAT FAILED: $f" >&2; failed=$((failed + 1)); fi
done
msg=$("$TB/jsontestrunner_exe" "$SRC/test/data/fail_test_array_01.json" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && echo "$msg" | grep -q "Missing ',' or ']' in array declaration"; then passed=$((passed + 1))
else echo "KAT FAILED: fail_test_array_01 (rc=$rc)" >&2; failed=$((failed + 1)); fi

emit_ctrf "jsoncpp_test+runjsontests" "$passed" "$failed" 0
