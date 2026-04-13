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
