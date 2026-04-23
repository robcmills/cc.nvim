# cc.nvim

A Neovim-native coding agent plugin built on the Claude Code CLI. Replaces the
Claude Code TUI with two Neovim buffers: an editable markdown prompt and a
foldable, progressive-disclosure output buffer.

## Why

I built this because I kept running into the same pain points using the
Claude Code TUI day-to-day, and eventually wanted a better UI for myself.
Most of these are well-documented in the `anthropics/claude-code` issue
tracker; cc.nvim sidesteps them by rendering into regular Neovim buffers
instead of taking over the terminal:

- **Scrollback:** Since the TUI switched to an alternate screen
  buffer ([#42670](https://github.com/anthropics/claude-code/issues/42670),
  [#28077](https://github.com/anthropics/claude-code/issues/28077)), you can't
  scroll up to read earlier messages — even ten messages back. And even if you
  are not facing these issues, the default verbose output includes a lot of
  tool results, which can quickly overflow your terminal scrollback limit
  (which helps perf), cutting off the beginning of the session.
  In a Neovim buffer it's just `gg` (reliably beginning of session), `G`
  (latest message/enter tail mode), `<C-u>` / `<C-d>` (page up/down), search,
  marks, yank (with no copy formatting issues caused by trailing whitespace).
- **Rendering flicker and redraw jitter.** Streaming tokens in the TUI repaint
  the whole screen; inside tmux this spirals into thousands of scroll
  events per second ([#9935](https://github.com/anthropics/claude-code/issues/9935),
  [#3648](https://github.com/anthropics/claude-code/issues/3648)). cc.nvim
  appends to a buffer — no alt-screen, no repaint storms.
- **Long sessions get sluggish.** The TUI holds and redraws the entire
  conversation from the top on every update. A buffer doesn't care how
  long the session is, and `history_max_records` caps resume rendering.
- **Freezes and hangs.** `/plan` freezing the UI
  ([#22032](https://github.com/anthropics/claude-code/issues/22032)) or
  the renderer deadlocking with no input accepted
  ([#25286](https://github.com/anthropics/claude-code/issues/25286)) —
  the only fix is killing the process from another terminal. cc.nvim
  runs `claude` as an async subprocess, so a stuck CLI never locks your
  editor, and `:CcStop` sends a proper `control_request` interrupt.
- **Tmux hostility.** Mouse-event capture breaks tmux copy/scroll
  ([#38810](https://github.com/anthropics/claude-code/issues/38810)); SSH
  and embedded terminals corrupt
  ([#13504](https://github.com/anthropics/claude-code/issues/13504),
  [#15875](https://github.com/anthropics/claude-code/issues/15875)). No
  mouse capture here — tmux copy mode just works.
- **Pasted text is collapsed to `[Pasted text +12 lines]`.** Painful to
  review or revise, especially when you're dictating with speech-to-text
  and need to scan what actually landed. The prompt buffer shows the
  full text, always.
- **Cramped input box.** The prompt is just a Neovim window — resize it
  to whatever height suits you, and use every vim motion, plugin, autocomplete,
  and keybinding you've already configured and are accustomed to.
- **Verbose tool output overflows everything.** Tool results are folded
  by default so session output stays scannable; when you do expand
  something, a configurable `max_tool_result_lines` caps how much renders.
  `:CcFold 0..3` toggles global disclosure levels. Foldlevel 1 is great for
  scanning sessions at a glance. Then open folds to dig in.

On top of avoiding the pain points above, cc.nvim uses the `claude` CLI
directly (zero extra dependencies beyond what you already have), so all
Claude Code features — skills, hooks, MCP servers, `CLAUDE.md`, your team
subscription auth — work out-of-the-box unmodified.

## Make it yours

In neovim tradition, cc.nvim is designed to be tailored.
Nearly every visible element is configurable:

- **Statusline.** Pass `statusline.format = function(state)
  ... end` and render whatever you want using standard Neovim statusline
  syntax. The `state` table hands you `is_thinking`, `spinner_frame`,
  `interrupt_pending`, `total_tokens`, `input_tokens`, `output_tokens`,
  `cost_usd`, `mode`, `branch`, `pr`, `model`, `cli_version`,
  `session_name`, `session_id`, and `remote_control` — build your own
  layout around any subset.
- **Per-tool input rendering.** `tool_input_format = function(tool_name,
  input) -> string | nil` lets you decide exactly how each tool's input
  is displayed below its header (custom Bash prefixes, compact Edit
  previews, summaries for your favorite MCP tool). Return `nil` for the
  built-in default.
- **Per-tool icons.** Every tool gets a glyph (nerdfont auto-detected,
  unicode fallback). Swap any of them: `tool_icons.icons = { Read = '📖',
  Bash = '$', MyMcpTool = '🔧' }`. Set a `default` for unknown tools.
- **Full highlight control.** `CcUser`, `CcAgent`, `CcTool`, `CcToolInput`,
  `CcOutput`, `CcError`, `CcCost`, `CcDiffAdd/Delete/Hunk`, `CcCaret`,
  `CcStl*`, and more — all link to existing colorscheme groups by default,
  so your theme drives them. Override any with `vim.api.nvim_set_hl`.
- **Layout knobs.** `layout = 'horizontal' | 'vertical'`, `prompt_height`,
  per-window `line_numbers` and `wrap`, `default_fold_level`,
  `max_tool_result_lines`, custom `foldtext` function.
- **Themes + interactive theme picker** *(coming soon).* A built-in
  gallery of visual mocks for every tool/turn type, with live theme
  switching so you can see your changes in real time.

See [Configuration](#configuration) and [Highlights](#highlights) for the
full list.

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
:CcNew
```

This opens a horizontal split: output buffer on top, editable markdown prompt
on the bottom. Type your message, then press `<CR>` in normal mode (or run
`:CcSend`) to submit. The response streams into the output buffer.

## Commands

| Command | Description |
|---|---|
| `:CcNew` | Open cc.nvim (spawn process, create buffers) |
| `:CcClose` | Close cc.nvim (kill process, close windows) |
| `:CcToggle` | Toggle visibility |
| `:CcClear` | Start a fresh session in the current windows |
| `:CcSend` | Submit the prompt buffer to the agent |
| `:CcStop` | Interrupt current turn (stream-json `control_request`) |
| `:CcFold {n}` | Set output fold level (0..3) |
| `:CcPlan` | Open in plan mode (`--permission-mode plan`) |
| `:CcPlanShow` | Open the most recent plan file |
| `:CcResume [id]` | Resume a session (picker if no id) |
| `:CcContinue` | Resume most recent session for current cwd |
| `:CcHistory` / `:CcHistory!` | Pick a session (! = all projects) |
| `:CcRename [name]` | Rename the current session (no arg = show current title) |
| `:CcDumpNdjson [path]` | Tee raw NDJSON from the subprocess to a file (no arg = stop) |

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
  default_fold_level = 2,      -- 0=minimal, 1=summaries, 2=inputs, 3=all
  max_tool_result_lines = 50,  -- tool results beyond this are truncated
  foldtext = nil,              -- function(info) -> string; nil = built-in default

  -- Tool input rendering: function(tool_name, input) -> string | nil
  -- Return a string to render below a tool header, or nil to use the default.
  tool_input_format = nil,

  -- History / resume
  history_max_records = 500,   -- cap records rendered on resume; older collapsed into a notice

  -- Display
  show_thinking = false,       -- show thinking blocks
  show_cost = true,            -- show cost/usage after each turn
  tool_icons = {
    use_nerdfont = nil,        -- nil = auto-detect; true/false forces
    default = nil,             -- icon for unknown tools
    icons = {},                -- per-tool overrides, e.g. { Read = '📖', Bash = '$' }
  },
  line_numbers = {
    output = false,            -- show line numbers in the output window
    prompt = false,            -- show line numbers in the prompt window
  },
  wrap = {
    output = true,             -- soft-wrap lines in the output window
    prompt = true,             -- soft-wrap lines in the prompt window
  },

  -- Statusline rendered at the bottom of the output window
  statusline = {
    enabled = true,
    format = nil,              -- function(state) -> string (Neovim statusline syntax)
    spinner = {
      use_nerdfont = nil,      -- nil = auto-detect; true/false forces
      frames = nil,            -- override; nil resolves to frames_nerdfont / frames_unicode
      interval_ms = 250,
    },
  },

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
| 1 | + agent text + tool summary lines (one-liners) |
| 2 *(default)* | + tool inputs (Bash commands, Edit diffs) |
| 3 | + tool results (stdout, read file contents) |

Every foldable header gets a caret prefix rendered as inline `virt_text`:
`▾` when open, `▸` when folded. Carets stay in sync with Vim's fold state
automatically. Tool headers use per-tool icons (nerdfont or unicode glyphs,
auto-detected) instead of a plain `Tool:` prefix.

Example at `foldlevel=1`:

```
▾ User:
    Fix the bug in auth.ts where tokens expire too early

▾ Agent:
    I'll look into the token expiration.
    ▸ 📖 Read: src/auth.ts
    ▸ ✏️ Edit: src/auth.ts
    ▸ $ Bash: npm test
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
4. cc.nvim client-side commands (e.g. `/rename`), intercepted in the plugin
   and not forwarded to the agent; yielded to upstream if the SDK ever
   claims the same name

Works with nvim-cmp (registered as source `cc_slash`) or via buffer-local
`omnifunc` (`<C-x><C-o>`) for users without nvim-cmp.

## Statusline

The output window gets its own statusline (requires `laststatus=2`, which
cc.nvim sets automatically when attaching). The default format shows:

- A spinner glyph (nerdfont or braille, auto-detected) while the agent is
  working — active from user submit through the final `result` message,
  covering tool calls and permission prompts. Shows `interrupting…` while
  a `:CcStop` is in flight and awaiting the CLI's acknowledgement.
- Cumulative session tokens (input + output)
- Permission mode
- Current git branch and PR number (if any)
- Session name / `⚡` remote-control indicator when applicable

Provide `statusline.format = function(state) ... end` to build your own.
The `state` table exposes `is_thinking`, `spinner_frame`, `interrupt_pending`,
`total_tokens`, `input_tokens`, `output_tokens`, `cost_usd`, `mode`, `branch`,
`pr`, `model`, `cli_version`, `session_name`, `session_id`, and
`remote_control`. Return a string using standard Neovim statusline syntax.

`:CcStop` (or `<C-c>`) sends a stream-json `control_request` with
`subtype: interrupt` on stdin. The process stays alive for the next turn;
"Interrupted" only renders once the CLI acknowledges via `control_response`.

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

### Renaming a session

Give the current session a custom title with either `/rename <name>` in
the prompt buffer or `:CcRename <name>` from anywhere. The slash form is
intercepted client-side (not forwarded to the agent); both share the same
code path and append a `custom-title` record to the session's JSONL file —
the same format the upstream Claude Code TUI uses, so renames round-trip
between the two. The new title surfaces in:

- the statusline `session_name` segment
- the `:CcHistory` picker (preferring `custom-title` > `ai-title` > first
  user message)
- the prompt buffer name (`cc-<name>`), since it's the only buflisted
  surface and therefore the one your buffer list sees

## Highlights

Default highlight groups (all linked to existing groups so your colorscheme
drives them):

| Group | Default link |
|---|---|
| `CcUser` | `Function` |
| `CcAgent` | `String` |
| `CcTool` | `Identifier` |
| `CcToolInput` | `Normal` |
| `CcOutput` | `Type` |
| `CcError` | `ErrorMsg` |
| `CcCost` | `Comment` |
| `CcNotice` | `WarningMsg` |
| `CcHook` | `Comment` |
| `CcPermission` | `WarningMsg` |
| `CcCaret` | `Comment` |
| `CcDiffAdd` | `DiffAdd` |
| `CcDiffDelete` | `DiffDelete` |
| `CcDiffHunk` | `DiffChange` |
| `CcStl` | (fg `#9aa5b1`) — statusline base |
| `CcStlTokens` | (fg `#a9e39a`) — token count segment |
| `CcStlMode` | (fg `#e6c07b`) — permission-mode segment |
| `CcStlBranch` | (fg `#c3a6ff`) — git branch / PR segment |

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
./tests/run.sh                        # all specs (minimal config)
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
│   ├── output_rendering_spec.lua    # user/agent turn headers, text rendering
│   ├── fold_spec.lua                # fold levels 0-3, :CcFold, foldtext summaries
│   ├── diff_rendering_spec.lua      # Edit/Write/MultiEdit diffs
│   ├── highlight_spec.lua           # CcXxx highlight group defaults
│   ├── caret_spec.lua               # ▾/▸ extmark sync with fold state
│   ├── icons_spec.lua               # per-tool icon resolution + nerdfont detection
│   ├── interactive_spec.lua         # AskUserQuestion, permissions, MCP elicitation
│   ├── interrupt_spec.lua           # :CcStop control_request / control_response flow
│   ├── statusline_spec.lua          # output-window statusline format + state
│   ├── statusline_spinner_spec.lua  # spinner timer lifecycle and frame resolution
│   ├── streaming_spec.lua           # streaming-only types: hooks, tool_progress, api_retry, etc.
│   ├── history_resume_spec.lua      # :CcResume transcript re-rendering
│   └── process_integration_spec.lua # full pipeline via fake_claude.sh subprocess
├── fixtures/
│   ├── jsonl/              # 18 JSONL fixtures (resume path — curated from real sessions)
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
  5 [fl=2    hl=CcTool       ]   ▸ 📖 Read: src/auth.ts
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

## Is this a pile of vibe coded slop?

Yes. Help me improve it: [CONTRIBUTING.md](CONTRIBUTING.md)

## Status

Feature-complete against the original plan. Small known gaps:

- Telescope picker for `:CcHistory` (current picker is `vim.ui.select`)
- Visual-selection context in `:CcSend` (include selection as file:line ref)

See [todo.md](todo.md) for current progress/informal roadmap.
