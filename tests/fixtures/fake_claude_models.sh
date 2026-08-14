#!/bin/bash
# Fake claude CLI for models-update integration tests. cc.models spawns
# `<cmd> -p --input-format stream-json ...`; this wrapper ignores the args
# and runs the NDJSON responder in tests/fixtures/fake_claude_models.lua.
exec nvim --clean -l "$(cd "$(dirname "$0")" && pwd)/fake_claude_models.lua"
