#!/usr/bin/env bash
# Runs every check a change must pass: analysis, formatting, the tests on
# the VM with line coverage of lib/src of at least 95%, the tests under
# Chrome, and the doc build. Exits non-zero at the first failure. The
# benchmark and scale suites are left to run on demand.
set -euo pipefail
cd "$(dirname "$0")/.."

step() {
  echo "== $*"
  "$@"
}

step dart analyze --fatal-infos
step dart format --output=none --set-exit-if-changed .
step dart run coverage:test_with_coverage --out coverage --scope-output libara
echo "== coverage of lib/src"
minimum=95
awk -F: -v minimum="$minimum" '
  /^SF:/ { inside = index($2, "lib/src/") > 0 }
  /^LF:/ && inside { found += $2 }
  /^LH:/ && inside { hit += $2 }
  END {
    percent = 100 * hit / found
    printf "%d of %d lines, %.2f%%, at least %d%% required\n", hit, found, percent, minimum
    exit percent < minimum
  }
' coverage/lcov.info
if command -v google-chrome >/dev/null 2>&1 ||
  command -v chromium >/dev/null 2>&1 ||
  [ -d "/Applications/Google Chrome.app" ]; then
  # One worker: browsers started in parallel time out loading suites on
  # a busy machine.
  step dart test -p chrome -j 1
else
  echo "== dart test -p chrome: skipped, no Chrome found"
fi
echo "== dart doc --dry-run"
doc="$(dart doc --dry-run 2>&1)"
echo "$doc" | tail -1
if ! echo "$doc" | grep -q "Found 0 warnings and 0 errors"; then
  echo "$doc" | grep -iE "warning|error"
  exit 1
fi
echo "== all checks passed"
