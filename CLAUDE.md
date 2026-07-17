# cc.nvim

Pure-Lua Neovim plugin that replaces the Claude Code TUI with two buffers — an
editable markdown prompt and a foldable output buffer. Spawns the `claude` CLI
as a persistent subprocess via `vim.uv.spawn()` and renders its NDJSON
`stream-json` protocol. Zero runtime dependencies beyond `claude` in `$PATH`
and Neovim 0.10+.

User-facing docs live in `README.md`; contributor guidance in `CONTRIBUTING.md`.
This file is for agents working in the repo.

## Architecture

Sessions are backed by a provider (`lua/cc/providers/`) selected by
`config.provider`: `claude` (default) or `codex`. A provider owns its
subprocess, wire protocol, history listing, and approval encoding, and
drives the shared renderer through provider-neutral entry points
(`output.lua` methods, `session.lua` fields). Never leak provider wire
messages into shared UI code; translate inside the provider.

Claude pipeline (one direction, top to bottom):

```
providers/claude.lua   provider interface (spawn/send/interrupt/history)
process.lua            spawn + stdio pipes (vim.uv)
parser.lua             NDJSON line buffer
router.lua             dispatch by message type
output.lua             render to buffer  ←→  session.lua  (turn/token/cost state)
```

Codex pipeline: `providers/codex.lua` spawns `codex app-server`, reuses
`parser.lua` for line splitting, and does JSON-RPC correlation + thread-item
→ render translation itself (no router). Protocol reference:
`codex app-server generate-json-schema --out <dir>` from the installed CLI;
verified against codex-cli 0.144.5.

- `plugin/cc.lua` registers `:Cc*` commands; `lua/cc/init.lua` is the public
  module and instance manager. Multiple sessions are supported, keyed by
  prompt bufnr in a module-level `instances` table. `attach_provider` in
  init.lua is the single construction path for new/clear/resume sessions.
- `lua/cc/output/` holds extracted render helpers (`cost`, `foldtext`,
  `timers`, `tool_body`). Most rendering work lands in `output.lua` plus
  one of these.
- NDJSON protocol reference (when extending message handling):
  `~/src/claude-code/src/entrypoints/sdk/coreSchemas.ts` and
  `~/src/claude-code/src/cli/structuredIO.ts`. **Caveat:** this local copy
  is a snapshot from around March 2026 and will never be updated. Treat any
  determination made from it as suspect and verify against the running CLI
  before relying on it. The further we get from that snapshot date, the more
  likely the source has drifted, and the more we'll have to reverse-engineer
  observed CLI behavior when it doesn't match what the source predicts.

## Testing

```bash
./tests/run.sh                      # all unit specs, minimal config (~6s)
./tests/run.sh <substring>          # filter unit specs by spec filename
./tests/run.sh --config=rob         # run with full user config
./tests/run.sh --e2e                # RPC-driven viewport/timing specs (slow)
./tests/run.sh --visual <fixture>   # render a fixture, print layer-C dump
./tests/run.sh --capture <name>     # record a new NDJSON fixture from a live session
```

- Built on `mini.test`, vendored at `tests/deps/mini.nvim` (git submodule —
  run `git submodule update --init --recursive` after a fresh clone).
- Unit specs in `tests/cases/*_spec.lua`; e2e in `tests/e2e/cases/`. Default
  `run.sh` runs unit only. Use `--e2e` when touching viewport, scroll, or
  real-timing behavior.
- One child neovim per spec file is shared across all its test cases — set
  it up with `hooks = helpers.shared_child_hooks()`. `pre_case` calls
  `reset_test_state` to wipe `cc-*` buffers, the `cc.output._buf_state`
  table, and registered cc instances. If a test needs a truly fresh
  child (e.g. depends on never-toggled fold state), give that group its
  own `pre_once` hook that stops and recreates `_G.child`.
- Codex tests: `codex_provider_spec.lua` feeds decoded JSON-RPC messages
  straight into the provider (stubbed transport); `codex_integration_spec.lua`
  spawns `tests/fixtures/fake_codex.sh` (a canned JSON-RPC responder) over
  real pipes. `tests/fixtures/codex/*.ndjson` holds captured server output.
- Two fixture paths to know about (Claude):
  - **JSONL** — resume path. `history.read_transcript` →
    `output:render_historical_record`. Tests final rendered state.
  - **NDJSON** — streaming path. `parser:feed` → `router:dispatch` → render.
    Tests live-streaming-only message types (hooks, `tool_progress`,
    `result`, `task_*`, `api_retry`, plan mode).
  - New rendering behavior usually wants a fixture in both.
- New behavior should come with a test.

## Style

- Pure Lua. No Vimscript outside `plugin/cc.lua` bootstrap.
- No build step, no formatter — match surrounding style.
- No new runtime dependencies. The point of this plugin is zero-deps.
- User-visible strings / icons / formats go through `lua/cc/config.lua` so
  users can override them.
- Public API changes should stay backwards-compatible when possible. Call
  out unavoidable breaks in the PR description.
- LuaCATS annotations (`---@class`, `---@field`, `---@param`) are used
  throughout — keep them current when you change types.

## Gotchas

- Render code runs from libuv callbacks. Wrap buffer mutations in
  `vim.schedule()` (existing pattern in `output.lua` and `router.lua`).
- Per-buffer state lives in module-level `_buf_state` tables keyed by
  `bufnr`. Teardown must wipe these or stale state leaks across sessions
  (see commit `ffd9057`).
- Carets (`▾` / `▸`) are extmark `virt_text` synced from Vim's fold state
  on `CursorMoved`. Don't rewrite them imperatively — change the fold
  state and let the sync run.

## Scope

In scope: anything that improves the editor experience of using the
`claude` CLI from Neovim. Out of scope: reimplementing things that belong
in the CLI itself (auth, model routing, MCP protocol internals). When in
doubt, open an issue first.
