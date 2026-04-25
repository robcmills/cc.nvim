#!/bin/bash
# Slow-streaming variant of fake_claude.sh: emits the fixture one NDJSON line
# at a time with a small inter-line sleep, so the parent's stdout pipe sees
# bytes arrive over many event-loop ticks (mirrors real claude streaming).
#
# Used by e2e viewport stress tests to expose timing-sensitive bugs in the
# output buffer's scroll/anchor logic.
#
# Env:
#   CC_TEST_FIXTURE  path to NDJSON fixture (required)
#   CC_TEST_DELAY_MS per-line delay in ms (default 25)

set -u

if [[ -z "${CC_TEST_FIXTURE:-}" ]]; then
  echo "fake_claude_slow.sh: CC_TEST_FIXTURE not set" >&2
  exit 1
fi
if [[ ! -f "$CC_TEST_FIXTURE" ]]; then
  echo "fake_claude_slow.sh: fixture not found: $CC_TEST_FIXTURE" >&2
  exit 1
fi

DELAY_MS="${CC_TEST_DELAY_MS:-25}"
# bash `sleep` accepts fractional seconds on macOS+linux.
DELAY_S=$(awk -v ms="$DELAY_MS" 'BEGIN{printf "%.3f", ms/1000}')

while IFS= read -r line; do
  printf '%s\n' "$line"
  sleep "$DELAY_S"
done < "$CC_TEST_FIXTURE"
