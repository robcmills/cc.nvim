# cc.nvim

A Neovim-native coding agent plugin built on the Claude Code CLI. Replaces the
Claude Code TUI with two Neovim buffers: an editable markdown prompt and a
foldable, progressive-disclosure output buffer.

## Why

- Claude Code's TUI has rendering bugs and verbose output that overflows
  terminal scrollback — in a buffer you can just scroll.
- The markdown prompt gives you every vim motion, plugin, and keybinding
  you've already configured. No cramped input box.
- Progressive disclosure folding lets long sessions stay readable: collapse
  every turn to a one-liner, expand only what you care about.
- Uses the `claude` CLI directly (zero extra dependencies beyond what you
  already have), so all Claude Code features — skills, hooks, MCP servers,
  `CLAUDE.md`, your team subscription auth — work unmodified.

## Requirements

- Neovim **0.10+** (required for inline `virt_text` carets)
- `claude` CLI in `$PATH`, version **2.1+** (for `--include-partial-messages`)
- Optional: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for richer slash
  command completion (an omnifunc fallback ships for users without it)

Verify with `:checkhealth cc` after installation.

## Installation

### Local directory (packer.nvim)

```lua
use {
  '/Users/you/src/cc.nvim',
  config = function() require('cc').setup() end,
}
```

### Manual / lazy load

```lua
vim.opt.runtimepath:prepend(vim.fn.expand('~/src/cc.nvim'))
require('cc').setup()
```

## Quick start

```vim
:CcOpen
```

This opens a horizontal split: output buffer on top, editable markdown prompt
on the bottom. Type your message, then press `<CR>` in normal mode (or run
`:CcSend`) to submit. The response streams into the output buffer.

## Commands

| Command | Description |
|---|---|
| `:CcOpen` | Open cc.nvim (spawn process, create buffers) |
| `:CcClose` | Close cc.nvim (kill process, close windows) |
| `:CcToggle` | Toggle visibility |
| `:CcSend` | Submit the prompt buffer to the agent |
| `:CcStop` | Interrupt current generation (SIGINT) |
| `:CcFold {n}` | Set output fold level (0..3) |
| `:CcPlan` | Open in plan mode (`--permission-mode plan`) |
| `:CcPlanShow` | Open the most recent plan file |
| `:CcResume [id]` | Resume a session (picker if no id) |
| `:CcContinue` | Resume most recent session for current cwd |
| `:CcHistory` / `:CcHistory!` | Pick a session (! = all projects) |

## Default keymaps

**Prompt buffer (normal mode):**

| Key | Action |
|---|---|
| `<CR>` | Submit prompt |
| `<C-c>` | Interrupt generation |
| `<C-l>` | Clear prompt buffer |
| `go` | Jump to output buffer |

**Output buffer:**

| Key | Action |
|---|---|
| `za` / `zo` / `zc` | Standard fold toggles |
| `zM` / `zR` | Collapse / expand all folds |
| `gp` | Jump to prompt buffer |

## Configuration

```lua
require('cc').setup({
  claude_cmd = 'claude',       -- path to claude binary
  permission_mode = nil,       -- nil | 'auto' | 'acceptEdits' | 'plan' | 'bypassPermissions'
  model = nil,                 -- nil | 'sonnet' | 'opus' | model string
  extra_args = {},             -- additional args passed to claude

  -- Layout
  layout = 'horizontal',       -- 'horizontal' | 'vertical'
  prompt_height = 10,          -- prompt buffer height (lines)

  -- Folding
  default_fold_level = 1,      -- 0=minimal, 1=summaries, 2=inputs, 3=all
  max_tool_result_lines = 50,  -- tool results beyond this are truncated

  -- History / resume
  history_max_records = 200,   -- cap records replayed on :CcResume

  -- Display
  show_thinking = false,       -- show thinking blocks
  show_cost = true,            -- show cost/usage after each turn

  -- Keymaps
  keymaps = {
    submit = '<CR>',
    interrupt = '<C-c>',
    clear_prompt = '<C-l>',
    goto_prompt = 'gp',
    goto_output = 'go',
  },
})
```

## Progressive disclosure

The output buffer is foldable with four logical levels:

| `foldlevel` | What's visible |
|---|---|
| 0 | Only User / Agent turn headers |
| 1 *(default)* | + agent text + tool summary lines (one-liners) |
| 2 | + tool inputs (Bash commands, Edit diffs) |
| 3 | + tool results (stdout, read file contents) |

Every foldable header gets a caret prefix rendered as inline `virt_text`:
`▾` when open, `▸` when folded. Carets stay in sync with Vim's fold state
automatically.

Example at `foldlevel=1`:

```
▾ User:
    Fix the bug in auth.ts where tokens expire too early

▾ Agent:
    I'll look into the token expiration.
    ▸ Tool: Read — src/auth.ts
    ▸ Tool: Edit — src/auth.ts
    ▸ Tool: Bash — npm test
    Fixed. The expiry was '1h'; changed to '24h'.
  ── $0.05 │ 12k in │ 55 out ──
```

Unfold a tool with `zo` to see the input (at level 2) or result (at level 3).
Change globally with `:CcFold 2` or the standard `zM` / `zR`.

## Interactive features

Claude Code's interactive tools get specialized UI:

- **Plan mode** (`:CcPlan`) — pass `--permission-mode plan` so edits are
  blocked until a plan is written. When the agent calls `ExitPlanMode`, a
  centered float previews the plan and `vim.ui.select` offers
  Approve / Reject (with optional reason) / Edit Plan.
- **AskUserQuestion** — opens `vim.ui.select` for single-choice, or a
  multi-step picker for `multiSelect: true` questions. Free-text "Other"
  always available.
- **MCP elicitation** — URL requests open in your browser via `vim.ui.open`;
  form requests prompt each schema field via `vim.ui.input`.
- **Permission prompts** — any other restricted tool triggers
  Allow / Deny / Always Allow (session).

## Slash command completion

In the prompt buffer, type `/` at the start of a line to trigger completion.
Sources (merged, project overrides user overrides session):

1. Built-ins + skills from the running session's system/init message
2. `~/.claude/commands/*.md` (YAML frontmatter `description:` used as detail)
3. `<cwd>/.claude/commands/*.md`

Works with nvim-cmp (registered as source `cc_slash`) or via buffer-local
`omnifunc` (`<C-x><C-o>`) for users without nvim-cmp.

## Session history

Every conversation is stored by Claude Code at
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.

- `:CcContinue` picks up the most recent session for your current directory
- `:CcHistory` opens a picker of all sessions in the current cwd
- `:CcHistory!` opens a picker across every project
- `:CcResume <id>` jumps to a specific session

When resuming, the prior transcript is re-rendered into the output buffer
(with inline diffs, tool calls, etc.) before the live session picks up.
Records are capped at `history_max_records` to keep long sessions snappy.

## Highlights

Default highlight groups (all linked to existing groups so your colorscheme
drives them):

| Group | Default link |
|---|---|
| `CcUser` | `Function` |
| `CcAgent` | `String` |
| `CcTool` | `Identifier` |
| `CcOutput` | `Type` |
| `CcError` | `ErrorMsg` |
| `CcCost` | `Comment` |
| `CcNotice` | `WarningMsg` |
| `CcHook` | `Comment` |
| `CcPermission` | `WarningMsg` |
| `CcCaret` | `Comment` |
| `CcSpinner` | `Comment` |
| `CcDiffAdd` | `DiffAdd` |
| `CcDiffDelete` | `DiffDelete` |
| `CcDiffHunk` | `DiffChange` |

Override any of them in your colorscheme or via `vim.api.nvim_set_hl`.

## Architecture

cc.nvim spawns the `claude` CLI as a persistent bidirectional subprocess:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --include-hook-events --verbose \
       [--resume <id>] [--permission-mode <mode>]
```

NDJSON flows in both directions:

- **stdout**: SDK messages (`system`, `stream_event`, `assistant`, `user`,
  `result`, `control_request`, `tool_progress`, `hook_*`, `task_*`, …)
- **stdin**: user messages and `control_response` for permission prompts

This is the same wire protocol the official Claude Agent SDK uses internally,
so all Claude Code features — auth, skills, hooks, MCP, CLAUDE.md — work
automatically.

Pure Lua. Uses `vim.uv.spawn()` for pipe-level control and `vim.schedule()`
to bridge libuv callbacks to the Neovim main loop.

## Testing

cc.nvim has a test suite built on [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md)
(vendored as a git submodule). Each test spawns a fresh Neovim child process
for full isolation.

### Running tests

```bash
./tests/run.sh                        # all 111 specs (minimal config)
./tests/run.sh output_rendering       # filter by spec file pattern
./tests/run.sh --config=rob           # run with Rob's full Neovim config
./tests/run.sh --visual simple_text   # render a fixture, print visual dump
./tests/run.sh --capture my_feature   # launch nvim with :CcDumpNdjson pre-armed
```

### Test structure

```
tests/
├── run.sh                  # entrypoint — supports --config, --visual, --capture, pattern filter
├── minimal_init.lua        # clean rtp: only cc.nvim + mini.nvim + $VIMRUNTIME
├── rob_init.lua            # sources ~/.config/nvim/init.lua (full user config)
├── helpers.lua             # render_fixture(), replay_streaming(), visual_dump(), assertion helpers
├── cases/
│   ├── output_rendering_spec.lua   # user/agent turn headers, text rendering
│   ├── fold_spec.lua               # fold levels 0-3, :CcFold, foldtext summaries
│   ├── diff_rendering_spec.lua     # Edit/Write/MultiEdit diffs
│   ├── highlight_spec.lua          # CcXxx highlight group defaults
│   ├── caret_spec.lua              # ▾/▸ extmark sync with fold state
│   ├── interactive_spec.lua        # AskUserQuestion, permissions, MCP elicitation
│   ├── streaming_spec.lua          # streaming-only types: hooks, tool_progress, api_retry, etc.
│   ├── history_resume_spec.lua     # :CcResume transcript re-rendering
│   └── process_integration_spec.lua # full pipeline via fake_claude.sh subprocess
├── fixtures/
│   ├── jsonl/              # 17 JSONL fixtures (resume path — curated from real sessions)
│   ├── ndjson/             # 11 NDJSON fixtures (streaming path — captured via :CcDumpNdjson)
│   ├── fake_claude.sh      # bash replay script for process-level integration tests
│   └── fake_claude.lua     # nvim-l replay script (alternative)
├── CLAUDE_CODE_FEATURES.md # raw Claude Code feature set audit
└── FEATURE_AUDIT.md        # cross-reference: CC features × cc.nvim coverage × test tiers
```

### Two fixture paths

Tests exercise two code paths that mirror how the plugin actually works:

- **JSONL (resume path):** `helpers.render_fixture()` loads a `.jsonl` file
  through `history.read_transcript()` → `output:render_historical_record()`.
  Tests the final rendered state of a conversation. This is the same path
  `:CcResume` uses.

- **NDJSON (streaming path):** `helpers.replay_streaming()` feeds a `.ndjson`
  file through `parser:feed()` → `router:dispatch()` → output rendering. Tests
  the live streaming code path including streaming-only message types (hook
  events, `tool_progress`, `result`/cost, `task_started`, `api_retry`, compact
  notices, plan mode).

### Capturing new fixtures

Use `:CcDumpNdjson <path>` during a live session to tee raw NDJSON bytes from
the `claude` subprocess to a file. This captures real streaming data for new
test fixtures:

```bash
# Interactive capture — opens cc.nvim with dump pre-armed
./tests/run.sh --capture my_new_feature
# Have a conversation that exercises the feature, then :qa!
# Fixture saved to tests/fixtures/ndjson/my_new_feature.ndjson
```

For JSONL fixtures, extract the relevant segment from a session file at
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.

### Visual dump mode

For debugging and development, `--visual` renders a fixture and prints an
annotated dump showing buffer lines, fold levels, highlight groups, and
extmarks — without running any assertions:

```bash
./tests/run.sh --visual tool_edit
```

```
  1 [fl=1    hl=CcUser       ] ▾ User:
  2 [fl=     hl=             ]     Fix auth bug
  3 [fl=1    hl=CcAgent      ] ▾ Agent:
  4 [fl=     hl=             ]     I'll look into it.
  5 [fl=2    hl=CcTool       ]   ▸ Tool: Read — src/auth.ts
      extmark=[('▸ ','CcCaret')]
```

### Writing tests

Tests use `mini.test` with child-process isolation. A typical test:

```lua
local helpers = require('tests.helpers')
local T = MiniTest.new_set()

T['render simple text'] = function()
  local child = helpers.new_child()
  helpers.render_fixture(child, 'simple_text')   -- JSONL resume path
  local lines = helpers.get_buffer_lines(child)
  MiniTest.expect.equality(lines[1], '▾ User:')
  child.stop()
end

T['stream simple text'] = function()
  local child = helpers.new_child()
  helpers.replay_streaming(child, 'simple_text')  -- NDJSON streaming path
  local lines = helpers.get_buffer_lines(child)
  MiniTest.expect.equality(lines[1], '▾ User:')
  child.stop()
end

return T
```

Available assertion helpers in `tests/helpers.lua`: `get_buffer_lines()`,
`get_fold_levels()`, `get_extmarks()`, `get_hl_at()`, `get_syn_stack()`,
`get_session_state()`.

## Troubleshooting

Run `:checkhealth cc`. It verifies:

- Neovim ≥ 0.10
- `claude` binary is in `$PATH`
- `claude` version ≥ 2.1
- libuv is available
- `claude auth status` succeeds

If slash completion doesn't trigger: ensure nvim-cmp is loaded before cc.nvim
sources its `plugin/cc.lua`, or fall back to `<C-x><C-o>` manually.

If carets don't appear: you need Neovim 0.10+ for inline `virt_text`.

## Status

Feature-complete against the original plan. Small known gaps:

- Telescope picker for `:CcHistory` (current picker is `vim.ui.select`)
- Richer status line integration (cost / permission mode indicators)
- Visual-selection context in `:CcSend` (include selection as file:line ref)
