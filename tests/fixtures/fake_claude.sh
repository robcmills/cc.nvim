#!/bin/bash
# Fake claude subprocess: replays an NDJSON fixture file to stdout.
# Used in process-level integration tests in place of the real `claude` CLI.
#
# Ignores all args (process.lua passes -p, --input-format, etc.).
# Reads fixture path from CC_TEST_FIXTURE env var.
#
# Usage:
#   CC_TEST_FIXTURE=path/to/file.ndjson fake_claude.sh [ignored args...]

if [[ -z "$CC_TEST_FIXTURE" ]]; then
  echo "fake_claude.sh: CC_TEST_FIXTURE not set" >&2
  exit 1
fi

if [[ ! -f "$CC_TEST_FIXTURE" ]]; then
  echo "fake_claude.sh: fixture not found: $CC_TEST_FIXTURE" >&2
  exit 1
fi

cat "$CC_TEST_FIXTURE"
