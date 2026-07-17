#!/bin/bash
# Fake codex CLI for integration tests. cc.nvim's codex provider spawns
# `<cmd> app-server`; this wrapper ignores the args and runs the JSON-RPC
# responder in tests/fixtures/fake_codex.lua.
exec nvim --clean -l "$(cd "$(dirname "$0")" && pwd)/fake_codex.lua"
